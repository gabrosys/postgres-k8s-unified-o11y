-- What: returns the id of the slowest trace of one query_id over the last __MIN__ minutes.
-- Why: it lets drill start from a query_id when you do not have a trace id yet.
SELECT argMax(TraceId, Duration)
FROM otel_traces
WHERE ServiceName = 'PostgreSQL_Server'
  AND SpanAttributes['query.query_id'] = '__QID__'
  AND ResourceAttributes['k8s.namespace.name'] = '__NS__'
  AND Timestamp > now() - INTERVAL __MIN__ MINUTE
