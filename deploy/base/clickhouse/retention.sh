#!/bin/bash
set -euo pipefail

source /scripts/ch.sh

# MODIFY TTL schedules a mutation, so skip it when nothing changed.
set_ttl() {
  local table="$1" expr="toDateTime($2) + toIntervalDay($3)"
  [ "$(ch "SELECT countIf(create_table_query LIKE '%TTL ${expr}%') FROM system.tables
           WHERE database = 'otel' AND name = '${table}'")" = 1 ] && return
  ch "ALTER TABLE otel.${table} ON CLUSTER otel MODIFY TTL ${expr}"
  echo "otel.${table}: TTL ${expr}"
}

set_ttl otel_traces Timestamp "$TRACES_TTL_DAYS"
set_ttl otel_traces_trace_id_ts Start "$TRACES_TTL_DAYS"
set_ttl otel_logs Timestamp "$LOGS_TTL_DAYS"
for kind in gauge sum histogram exponential_histogram summary; do
  set_ttl "otel_metrics_${kind}" TimeUnix "$METRICS_TTL_DAYS"
done
