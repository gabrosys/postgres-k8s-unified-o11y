#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_kind_context

# series TABLE METRIC LABEL [FILTER]: distinct LABEL values reporting METRIC in the last 5 minutes.
series() {
  count "SELECT uniqExact($3) FROM otel_metrics_$1 WHERE MetricName = '$2'
         AND TimeUnix > now() - INTERVAL 5 MINUTE ${4:+AND $4}"
}
pod="ResourceAttributes['k8s.pod.name']"
gateways=$(kubectl get statefulset otel-gateway-collector -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
replicas=$(kubectl get chi otel -n "$NAMESPACE" -o jsonpath='{.status.hosts}')

expect() {
  [ "$2" = "$3" ] && pass "$1 from $2" || fail "$1: ${2:-0} reporting, expected $3"
}
expect "gateway queue size" "$(series gauge otelcol_exporter_queue_size "$pod" "$pod LIKE 'otel-gateway-%'")" "$gateways"
expect "gateway refused spans" "$(series sum otelcol_receiver_refused_spans "$pod" "$pod LIKE 'otel-gateway-%'")" "$gateways"
expect "ClickHouse max parts per partition" "$(series gauge ClickHouseAsyncMetrics_MaxPartCountForPartition "$pod")" "$replicas"
expect "ClickHouse failed inserts" "$(series sum ClickHouseProfileEvents_FailedInsertQuery "$pod")" "$replicas"
for c in "${CLUSTERS[@]}"; do
  instances=$(kubectl get cluster "$PG_NAME" -n "$c" -o jsonpath='{.spec.instances}')
  expect "${c}: pg_stat_ch dropped events" \
    "$(series sum cnpg_pg_stat_ch_dropped_events "$pod" "ResourceAttributes['k8s.namespace.name'] = '${c}'")" "$instances"
done

exit "$FAILED"
