#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_kind_context

# Synthetic data in a throwaway database on one ClickHouse host. Pod b is the
# primary and reads 600 blocks and 60 CPU seconds a minute; pod a is a replica
# whose counters are higher but flat.
DB="timeline_$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
trap 'ch_query "DROP DATABASE IF EXISTS ${DB}" >/dev/null 2>&1 || true' EXIT

ch_query "CREATE DATABASE ${DB}"
for t in otel_logs otel_traces otel_metrics_sum; do
  ch_query "CREATE TABLE ${DB}.${t} AS otel.${t} ENGINE = Memory"
done

ch_query "
  INSERT INTO ${DB}.otel_logs (Timestamp, ServiceName, ResourceAttributes, LogAttributes)
  SELECT toStartOfMinute(now()) - toIntervalMinute(number + 1) + 10, 'pg_stat_ch',
         map('k8s.namespace.name', 'tl'), map('query_id', '42', 'duration_us', '1000')
  FROM numbers(3)"

ch_query "
  INSERT INTO ${DB}.otel_metrics_sum (TimeUnix, MetricName, Value, ResourceAttributes, Attributes)
  SELECT toStartOfMinute(now()) - toIntervalMinute(4 - n) + 10, metric,
         if(pod = 'a', flat, step * n), map('k8s.namespace.name', 'tl'), attrs
  FROM (SELECT number AS n FROM numbers(4)) AS minutes
  CROSS JOIN (
    SELECT 'a' AS pod, 'cnpg_pg_stat_database_blks_read' AS metric, 100000 AS flat, 600 AS step,
           map('pod', 'a', 'datname', 'tpcc') AS attrs
    UNION ALL SELECT 'b', 'cnpg_pg_stat_database_blks_read', 0, 600, map('pod', 'b', 'datname', 'tpcc')
    UNION ALL SELECT 'a', 'container_cpu_usage_seconds_total', 5000, 60,
           map('pod', 'a', 'id', 'ca', 'namespace', 'tl', 'container', 'postgres')
    UNION ALL SELECT 'b', 'container_cpu_usage_seconds_total', 0, 60,
           map('pod', 'b', 'id', 'cb', 'namespace', 'tl', 'container', 'postgres')) AS series"

rows=$(CH_DATABASE="$DB" CH_FORMAT=TSV PG_CLUSTER=tl QUERY_ID=42 \
  "${ROOT_DIR}/scripts/correlate.sh" timeline 2>/dev/null || true)
echo "$rows"

[ "$(wc -l <<< "$rows" | tr -d ' ')" = 3 ] && pass "timeline has one row per minute" || fail "timeline rows: ${rows:-none}"
awk -F'\t' '$4 != 10 || $5 != 1 { bad = 1 } END { exit bad }' <<< "$rows" \
  && pass "timeline sums disk reads and CPU over the cluster's pods" \
  || fail "timeline mixes counters of different pods"

exit "$FAILED"
