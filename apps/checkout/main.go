package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"math/rand/v2"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

type app struct {
	pool   *pgxpool.Pool
	tracer trace.Tracer
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx); err != nil {
		log.Fatal(err)
	}
}

func run(ctx context.Context) error {
	exp, err := otlptracegrpc.New(ctx)
	if err != nil {
		return fmt.Errorf("otlp exporter: %w", err)
	}
	tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(exp))
	defer func() {
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := tp.Shutdown(sctx); err != nil {
			log.Printf("tracer shutdown: %v", err)
		}
	}()
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.TraceContext{})

	cfg, err := pgxpool.ParseConfig("")
	if err != nil {
		return fmt.Errorf("pool config: %w", err)
	}
	cfg.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeExec
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return fmt.Errorf("pool: %w", err)
	}
	defer pool.Close()

	a := &app{pool: pool, tracer: tp.Tracer("checkout")}
	mux := http.NewServeMux()
	mux.Handle("POST /checkout", otelhttp.NewHandler(http.HandlerFunc(a.checkout), "POST /checkout"))
	mux.HandleFunc("GET /healthz", a.healthz)

	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()

	select {
	case err := <-errc:
		return fmt.Errorf("listen: %w", err)
	case <-ctx.Done():
	}
	sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(sctx); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("shutdown: %w", err)
	}
	return nil
}

func (a *app) healthz(w http.ResponseWriter, r *http.Request) {
	if err := a.pool.Ping(r.Context()); err != nil {
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
	}
}

func (a *app) checkout(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	traceID := trace.SpanContextFromContext(ctx).TraceID().String()
	w.Header().Set("X-Trace-Id", traceID)
	if err := a.order(ctx, traceID); err != nil {
		trace.SpanFromContext(ctx).RecordError(err)
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

// order runs autocommit statements, each in its own client span: pg_tracing parents an
// explicit transaction block to the trace id instead of the caller's span. The writes share
// one statement so stock and order stay consistent.
func (a *app) order(ctx context.Context, traceID string) error {
	wID, dID, cID, iID := 1+rand.IntN(4), 1+rand.IntN(10), 1+rand.IntN(3000), 1+rand.IntN(100000)

	var discount, price float64
	var bought int64
	steps := []struct {
		name, sql string
		do        func(ctx context.Context, sql string) error
	}{
		{"checkout.read_customer", "SELECT c_discount FROM customer WHERE c_w_id = $1 AND c_d_id = $2 AND c_id = $3",
			func(ctx context.Context, sql string) error {
				return a.pool.QueryRow(ctx, sql, wID, dID, cID).Scan(&discount)
			}},
		{"checkout.read_item", "SELECT i_price FROM item WHERE i_id = $1",
			func(ctx context.Context, sql string) error { return a.pool.QueryRow(ctx, sql, iID).Scan(&price) }},
		{"checkout.item_history", "SELECT count(*) FROM order_line WHERE ol_i_id = $1",
			func(ctx context.Context, sql string) error { return a.pool.QueryRow(ctx, sql, iID).Scan(&bought) }},
		{"checkout.place_order", `WITH stock AS (
  UPDATE stock SET s_quantity = CASE WHEN s_quantity > 10 THEN s_quantity - 1 ELSE s_quantity + 91 END
  WHERE s_w_id = $1 AND s_i_id = $2 RETURNING s_i_id)
INSERT INTO checkout_orders (trace_id, w_id, i_id) SELECT $3, $1, s_i_id FROM stock`,
			func(ctx context.Context, sql string) error {
				_, err := a.pool.Exec(ctx, sql, wID, iID, traceID)
				return err
			}},
	}
	for _, s := range steps {
		if err := a.statement(ctx, s.name, s.sql, s.do); err != nil {
			return fmt.Errorf("%s: %w", s.name, err)
		}
	}
	return nil
}

// statement runs one SQL statement inside a client span whose context is sent to Postgres.
func (a *app) statement(ctx context.Context, name, sql string, do func(context.Context, string) error) error {
	ctx, span := a.tracer.Start(ctx, name, trace.WithSpanKind(trace.SpanKindClient), trace.WithAttributes(
		attribute.String("db.system.name", "postgresql"),
		attribute.String("db.query.text", sql),
	))
	defer span.End()
	if err := do(ctx, withTraceparent(ctx, sql)); err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return err
	}
	return nil
}
