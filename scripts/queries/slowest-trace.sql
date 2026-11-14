-- Slowest trace of one query_id, so drill can start from a query_id.
SELECT argMax(TraceId, Duration)
FROM otel_traces
WHERE ServiceName = 'PostgreSQL_Server'
  AND SpanAttributes['query.query_id'] = '__QID__'
  AND ResourceAttributes['k8s.namespace.name'] = '__NS__'
  AND Timestamp > now() - INTERVAL __MIN__ MINUTE
