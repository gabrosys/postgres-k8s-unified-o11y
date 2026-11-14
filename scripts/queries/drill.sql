-- Spans and server-log lines of one trace, in time order. A log line belongs to the
-- trace when it carries the traceparent, or when its pod, backend pid and query_id
-- match a span and it was written while the trace ran.
WITH spans AS (
  SELECT Timestamp, Duration, ServiceName, SpanName,
         ResourceAttributes['k8s.pod.name'] AS pod,
         SpanAttributes['backend.pid'] AS pid,
         SpanAttributes['query.query_id'] AS qid
  FROM otel_traces
  WHERE TraceId = '__TRACE__'
)
SELECT * FROM (
  SELECT Timestamp AS ts, 'span' AS src, ServiceName AS who,
         round(Duration / 1e6, 2) AS ms, substring(SpanName, 1, 90) AS what
  FROM spans
  UNION ALL
  SELECT Timestamp, 'log', ResourceAttributes['k8s.pod.name'],
         toFloat64OrNull(extract(JSONExtractString(Body, 'message'), 'duration: ([0-9.]+) ms')),
         substring(replaceRegexpOne(JSONExtractString(Body, 'message'), '/\\*traceparent=.*?\\*/ ', ''), 1, 90)
  FROM otel_logs
  WHERE ServiceName = 'postgres-server-log'
    AND (position(Body, '__TRACE__') > 0
         OR ((ResourceAttributes['k8s.pod.name'], JSONExtractString(Body, 'process_id'), LogAttributes['query_id'])
               IN (SELECT pod, pid, qid FROM spans WHERE qid NOT IN ('', '0'))
             AND Timestamp BETWEEN (SELECT min(Timestamp) FROM spans)
                               AND (SELECT max(Timestamp + toIntervalNanosecond(Duration)) FROM spans) + INTERVAL 1 SECOND))
) ORDER BY ts
