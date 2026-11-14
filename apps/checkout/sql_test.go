package main

import (
	"context"
	"testing"

	"go.opentelemetry.io/otel/trace"
)

func TestWithTraceparent(t *testing.T) {
	tid, _ := trace.TraceIDFromHex("0af7651916cd43dd8448eb211c80319c")
	sid, _ := trace.SpanIDFromHex("b7ad6b7169203331")
	span := func(flags trace.TraceFlags) context.Context {
		sc := trace.NewSpanContext(trace.SpanContextConfig{TraceID: tid, SpanID: sid, TraceFlags: flags})
		return trace.ContextWithSpanContext(context.Background(), sc)
	}

	tests := []struct {
		name string
		ctx  context.Context
		want string
	}{
		{"sampled", span(trace.FlagsSampled), "/*traceparent='00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01'*/ SELECT 1"},
		{"no span", context.Background(), "SELECT 1"},
		{"unsampled", span(0), "SELECT 1"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := withTraceparent(tt.ctx, "SELECT 1"); got != tt.want {
				t.Errorf("withTraceparent() = %q, want %q", got, tt.want)
			}
		})
	}
}
