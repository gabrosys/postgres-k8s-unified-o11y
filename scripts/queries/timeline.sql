-- What: one row per complete minute for one query_id on __NS__. It joins that query's latency
-- (events) and slowest trace with the pod's disk reads and CPU (metrics).
-- Why: events, traces and metrics sit side by side, so a regression and its cost show up in the
-- same minute. The metric columns cover the whole pod, not just this query.
-- The current minute is left out because it is partial, and the metrics read one extra minute
-- back so the first row has a previous counter value to subtract.
WITH
  toStartOfMinute(now()) AS e,
  e - INTERVAL __MIN__ MINUTE AS s,
  ev AS (
    SELECT toStartOfMinute(Timestamp) AS m,
           count() AS calls,
           round(quantile(0.95)(toFloat64OrZero(LogAttributes['duration_us'])) / 1000, 2) AS p95_ms
    FROM otel_logs
    WHERE ServiceName = 'pg_stat_ch'
      AND ResourceAttributes['k8s.namespace.name'] = '__NS__'
      AND LogAttributes['query_id'] = '__QID__'
      AND Timestamp >= s AND Timestamp < e
    GROUP BY m),
  blk AS (
    SELECT m, round(greatest(v - lagInFrame(v, 1, v) OVER (ORDER BY m), 0) / 60, 1) AS blks_read_s
    FROM (SELECT toStartOfMinute(TimeUnix) AS m, max(Value) AS v
          FROM otel_metrics_sum
          WHERE MetricName = 'cnpg_pg_stat_database_blks_read'
            AND ResourceAttributes['k8s.namespace.name'] = '__NS__'
            AND Attributes['datname'] = 'demo'
            AND TimeUnix >= s - INTERVAL 1 MINUTE AND TimeUnix < e
          GROUP BY m)),
  cpu AS (
    SELECT m, round(greatest(v - lagInFrame(v, 1, v) OVER (ORDER BY m), 0) / 60, 3) AS cpu_cores
    FROM (SELECT toStartOfMinute(TimeUnix) AS m, max(Value) AS v
          FROM otel_metrics_sum
          WHERE MetricName = 'container_cpu_usage_seconds_total'
            AND Attributes['namespace'] = '__NS__' AND Attributes['container'] = 'postgres'
            AND TimeUnix >= s - INTERVAL 1 MINUTE AND TimeUnix < e
          GROUP BY m)),
  tr AS (
    SELECT toStartOfMinute(Timestamp) AS m,
           round(max(Duration) / 1e6, 1) AS worst_ms,
           argMax(TraceId, Duration) AS worst_trace
    FROM otel_traces
    WHERE ServiceName = 'PostgreSQL_Server'
      AND SpanAttributes['query.query_id'] = '__QID__'
      AND ResourceAttributes['k8s.namespace.name'] = '__NS__'
      AND Timestamp >= s AND Timestamp < e
    GROUP BY m)
SELECT formatDateTime(m, '%H:%i') AS minute, calls, p95_ms, blks_read_s, cpu_cores, worst_ms, worst_trace
FROM ev
LEFT JOIN blk USING (m)
LEFT JOIN cpu USING (m)
LEFT JOIN tr USING (m)
ORDER BY m DESC
SETTINGS join_use_nulls = 1
