package main

import (
	"context"

	"go.opentelemetry.io/otel/trace"
)

// withTraceparent prefixes sql with the caller's sampled span so pg_tracing nests its spans under it.
func withTraceparent(ctx context.Context, sql string) string {
	sc := trace.SpanContextFromContext(ctx)
	if !sc.IsValid() || !sc.IsSampled() {
		return sql
	}
	return "/*traceparent='00-" + sc.TraceID().String() + "-" + sc.SpanID().String() + "-01'*/ " + sql
}
