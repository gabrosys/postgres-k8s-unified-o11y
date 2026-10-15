-- What: lists the spans and the server-log lines of one trace in time order.
-- Why: the server log carries the traceparent, so traces and logs join on the trace id. One
-- result shows where the time went and what PostgreSQL logged for the same request.
SELECT * FROM (
  SELECT Timestamp AS ts, 'span' AS src, ServiceName AS who,
         round(Duration / 1e6, 2) AS ms, substring(SpanName, 1, 90) AS what
  FROM otel_traces
  WHERE TraceId = '__TRACE__'
  UNION ALL
  SELECT Timestamp, 'log', ResourceAttributes['k8s.pod.name'],
         toFloat64OrNull(extract(JSONExtractString(Body, 'message'), 'duration: ([0-9.]+) ms')),
         substring(replaceRegexpOne(JSONExtractString(Body, 'message'), '/\\*traceparent=.*?\\*/ ', ''), 1, 90)
  FROM otel_logs
  WHERE ServiceName = 'postgres-server-log' AND position(Body, '__TRACE__') > 0
) ORDER BY ts
