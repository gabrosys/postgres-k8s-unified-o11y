-- Per complete minute: one query's latency and slowest trace next to the cluster's
-- disk reads and CPU. Metrics start a minute early so the first row has a counter to subtract.
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
  -- Counters differ per pod and restart with a container, so each series gets its
  -- own per-minute delta before they are summed over the cluster.
  rates AS (
    SELECT m,
           round(sumIf(d, MetricName = 'cnpg_pg_stat_database_blks_read') / 60, 1) AS blks_read_s,
           round(sumIf(d, MetricName = 'container_cpu_usage_seconds_total') / 60, 3) AS cpu_cores
    FROM (
      SELECT MetricName, m,
             greatest(v - lagInFrame(v, 1, v) OVER (PARTITION BY MetricName, series ORDER BY m), 0) AS d
      FROM (SELECT MetricName, concat(Attributes['pod'], '/', Attributes['id']) AS series,
                   toStartOfMinute(TimeUnix) AS m, max(Value) AS v
            FROM otel_metrics_sum
            WHERE ((MetricName = 'cnpg_pg_stat_database_blks_read'
                    AND ResourceAttributes['k8s.namespace.name'] = '__NS__' AND Attributes['datname'] = 'tpcc')
                OR (MetricName = 'container_cpu_usage_seconds_total'
                    AND Attributes['namespace'] = '__NS__' AND Attributes['container'] = 'postgres'))
              AND bitAnd(Flags, 1) = 0
              AND TimeUnix >= s - INTERVAL 1 MINUTE AND TimeUnix < e
            GROUP BY MetricName, series, m))
    GROUP BY m),
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
LEFT JOIN rates USING (m)
LEFT JOIN tr USING (m)
ORDER BY m DESC
SETTINGS join_use_nulls = 1
