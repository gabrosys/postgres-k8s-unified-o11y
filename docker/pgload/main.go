package main

import (
	"context"
	"fmt"
	"log"
	"math/rand/v2"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

const seedRows = 200000

var tracer trace.Tracer

type shape struct {
	name string
	sql  string
	args func() []any
}

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	shutdown, err := initTracing(ctx)
	if err != nil {
		return fmt.Errorf("tracing: %w", err)
	}
	defer shutdown()

	pool, err := pgxpool.New(ctx, "")
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer pool.Close()

	if err := seed(ctx, pool); err != nil {
		return fmt.Errorf("seed: %w", err)
	}

	shapes := []shape{
		{"lookup", "SELECT id, kind, amount FROM pgload_events WHERE ext_id = $1",
			func() []any { return []any{fmt.Sprintf("ext-%d", rand.IntN(seedRows)+1)} }},
		{"summary", "SELECT kind, count(*), avg(amount) FROM pgload_events WHERE id < $1 GROUP BY kind",
			func() []any { return []any{5000} }},
		{"scan", "SELECT count(*) FROM pgload_events WHERE payload LIKE $1",
			func() []any { return []any{"%deadbeef%"} }},
	}

	rate := envFloat("RATE_PER_SEC", 3)
	ticker := time.NewTicker(time.Duration(float64(time.Second) / rate))
	defer ticker.Stop()

	log.Printf("pgload running at %.2f queries/sec", rate)
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			query(ctx, pool, pick(shapes))
		}
	}
}

func pick(s []shape) shape {
	switch r := rand.Float64(); {
	case r < 0.90:
		return s[0]
	case r < 0.98:
		return s[1]
	default:
		return s[2]
	}
}

func query(ctx context.Context, pool *pgxpool.Pool, s shape) {
	ctx, span := tracer.Start(ctx, s.name, trace.WithSpanKind(trace.SpanKindClient))
	defer span.End()
	span.SetAttributes(attribute.String("db.query.text", s.sql))

	if _, err := pool.Exec(ctx, traced(ctx, s.sql), s.args()...); err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		log.Printf("%s: %v", s.name, err)
	}
}

// A leading comment keeps the traceparent out of the normalized query text.
func traced(ctx context.Context, sql string) string {
	carrier := propagation.MapCarrier{}
	otel.GetTextMapPropagator().Inject(ctx, carrier)
	tp := carrier["traceparent"]
	if tp == "" {
		return sql
	}
	return fmt.Sprintf("/*traceparent='%s'*/ %s", tp, sql)
}

func seed(ctx context.Context, pool *pgxpool.Pool) error {
	if _, err := pool.Exec(ctx, `CREATE TABLE IF NOT EXISTS pgload_events (
		id         bigserial PRIMARY KEY,
		ext_id     text NOT NULL,
		kind       text NOT NULL,
		amount     numeric(10,2) NOT NULL,
		payload    text NOT NULL,
		created_at timestamptz NOT NULL DEFAULT now())`); err != nil {
		return err
	}

	var n int64
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM pgload_events").Scan(&n); err != nil {
		return err
	}
	// Created with the data only, so a dropped index stays dropped across restarts.
	if n > 0 {
		return nil
	}

	log.Printf("seeding %d rows", seedRows)
	if _, err := pool.Exec(ctx, `INSERT INTO pgload_events (ext_id, kind, amount, payload)
		SELECT 'ext-' || g,
		       (ARRAY['order','refund','shipment'])[1 + floor(random() * 3)],
		       (random() * 100)::numeric(10,2),
		       md5(g::text) || md5((g * 7)::text)
		FROM generate_series(1, $1) g`, seedRows); err != nil {
		return err
	}

	if _, err := pool.Exec(ctx, "CREATE INDEX pgload_events_ext_id_idx ON pgload_events (ext_id)"); err != nil {
		return err
	}
	_, err := pool.Exec(ctx, "ANALYZE pgload_events")
	return err
}

func initTracing(ctx context.Context) (func(), error) {
	exporter, err := otlptracehttp.New(ctx)
	if err != nil {
		return nil, err
	}
	res, err := resource.New(ctx, resource.WithFromEnv())
	if err != nil {
		return nil, err
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	tracer = tp.Tracer("pgload")

	return func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := tp.Shutdown(shutdownCtx); err != nil {
			log.Printf("tracer shutdown: %v", err)
		}
	}, nil
}

func envFloat(key string, fallback float64) float64 {
	v, err := strconv.ParseFloat(os.Getenv(key), 64)
	if err != nil || v <= 0 {
		return fallback
	}
	return v
}
