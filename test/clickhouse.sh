#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_kind_context
CH_DATABASE=default

as_grafana() { CH_USER=grafana CH_PASSWORD="$(ch_secret grafana)" ch_query "$1"; }

# expect_error CODE LABEL SQL: passes only when grafana's SQL fails with ClickHouse error CODE.
expect_error() {
  local out
  out=$(as_grafana "$3" 2>&1 || true)
  grep -q "Code: $1\." <<< "$out" && pass "$2" || fail "$2"
}

n=$(kubectl get pods -n "$NAMESPACE" -l "clickhouse.altinity.com/chi=otel" \
      -o jsonpath='{range .items[?(@.status.containerStatuses[0].ready==true)]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l)
[ "$n" -eq 2 ] && pass "2 ClickHouse replicas Ready on distinct nodes" || fail "${n} distinct nodes with a Ready replica, expected 2"

want=$(kubectl get chit otel-sizing -n "$NAMESPACE" \
         -o jsonpath='{.spec.templates.podTemplates[0].spec.containers[0].resources.limits.memory}' 2>/dev/null || true)
got=$(kubectl get pods -n "$NAMESPACE" -l clickhouse.altinity.com/chi=otel \
        -o jsonpath='{.items[*].spec.containers[?(@.name=="clickhouse")].resources.limits.memory}' | tr ' ' '\n' | sort -u)
[ -n "$want" ] && [ "$got" = "$want" ] && pass "replicas sized by template otel-sizing (${want})" \
  || fail "replica memory limit '${got}', template otel-sizing says '${want:-missing}'"

replicas=$(count "SELECT count() FROM system.clusters WHERE cluster = 'otel'")
[ "$replicas" = 2 ] && pass "cluster otel has 2 replicas" || fail "cluster otel has ${replicas:-no} replicas, expected 2"
check_rows "Keeper reachable (%n root znodes)" \
  "SELECT count() FROM system.zookeeper WHERE path = '/'"

pdb=$(kubectl get pdb -n "$NAMESPACE" -o json \
  | jq '[.items[] | select(.spec.selector.matchLabels["clickhouse.altinity.com/chi"] == "otel" and .spec.maxUnavailable == 1)] | length')
check "$pdb" "ClickHouse PodDisruptionBudget with maxUnavailable 1"

check_rows "Prometheus endpoint exposes %n metric lines" \
  "SELECT count() FROM url('http://127.0.0.1:9363/metrics', 'LineAsString')"

expect_error 164 "grafana cannot write" "CREATE TABLE default.grafana_write_probe (x UInt8) ENGINE = Memory"
[ "$(as_grafana "SELECT getSetting('max_execution_time') > 0 AND getSetting('max_memory_usage') > 0" 2>/dev/null)" = "1" ] \
  && pass "grafana profile sets execution and memory limits" || fail "grafana profile limits missing"
expect_error 452 "grafana cannot lift max_memory_usage" "SELECT 1 SETTINGS max_memory_usage = 0"

exit "$FAILED"
