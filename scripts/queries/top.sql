-- Statements ranked by total time, from pg_stat_ch events.
SELECT query_id,
       count() AS calls,
       round(sum(d) / 1e6, 2) AS total_s,
       round(100 * sum(d) / sum(sum(d)) OVER (), 1) AS pct_time,
       round(avg(d) / 1000, 2) AS avg_ms,
       round(quantile(0.95)(d) / 1000, 2) AS p95_ms,
       substring(any(q), 1, 70) AS query
FROM (SELECT LogAttributes['query_id'] AS query_id,
             LogAttributes['db.query.text'] AS q,
             toFloat64OrZero(LogAttributes['duration_us']) AS d
      FROM otel_logs
      WHERE ServiceName = 'pg_stat_ch'
        AND ResourceAttributes['k8s.namespace.name'] = '__NS__'
        AND LogAttributes['query_id'] NOT IN ('', '0')
        AND Timestamp > now() - INTERVAL __MIN__ MINUTE)
GROUP BY query_id
ORDER BY total_s DESC
LIMIT 5
