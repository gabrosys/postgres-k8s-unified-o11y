#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_kind_context

ready_nodes() {
  kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=$1" \
    -o jsonpath='{range .items[?(@.status.containerStatuses[0].ready==true)]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l | tr -d ' '
}

n=$(ready_nodes otel-gateway-collector)
[ "$n" -eq 2 ] && pass "gateway: 2 replicas Ready on distinct nodes" || fail "gateway: ${n} nodes with a Ready replica, expected 2"

bound=$(kubectl get pvc -n "$NAMESPACE" \
          -o jsonpath='{range .items[?(@.status.phase=="Bound")]}{.metadata.name}{"\n"}{end}' \
        | grep -c '^queue-otel-gateway-collector-' || true)
[ "$bound" -eq 2 ] && pass "gateway: one queue PVC Bound per replica" || fail "gateway: ${bound} queue PVCs Bound, expected 2"

pdb=$(kubectl get pdb -n "$NAMESPACE" -l app.kubernetes.io/name=otel-gateway-collector --no-headers 2>/dev/null | wc -l | tr -d ' ')
check "$pdb" "gateway: PodDisruptionBudget present"

desired=$(kubectl get ds otel-agent-collector -n "$NAMESPACE" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
ready=$(kubectl get ds otel-agent-collector -n "$NAMESPACE" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
[ "${desired:-0}" -gt 0 ] && [ "$desired" = "$ready" ] && pass "agent: ${ready}/${desired} Ready" || fail "agent: ${ready:-0}/${desired:-0} Ready"

check "$(ready_nodes otel-scraper-targetallocator)" "scraper: target allocator Ready"
check "$(ready_nodes otel-scraper-collector)" "scraper: collector Ready"

gateway_reporters() {
  count "SELECT uniqExact(ResourceAttributes['k8s.pod.name']) FROM otel_metrics_gauge
         WHERE MetricName = 'otelcol_exporter_queue_size' AND Attributes['exporter'] = 'clickhouse'
           AND bitAnd(Flags, 1) = 0 AND TimeUnix > now() - INTERVAL 5 MINUTE"
}
gateway_reports_both() { [ "$(gateway_reporters)" = 2 ]; }

# One scrape interval plus a queue flush.
wait_for 180 gateway_reports_both \
  && pass "self-metrics: queue size from both gateway replicas" \
  || fail "self-metrics: queue size from $(gateway_reporters) gateway replicas, expected 2"
gateways_receiving() {
  count "SELECT countIf(d > 0) FROM (
           SELECT max(Value) - min(Value) AS d FROM otel_metrics_sum
           WHERE MetricName = 'otelcol_receiver_accepted_metric_points' AND bitAnd(Flags, 1) = 0
             AND ResourceAttributes['k8s.pod.name'] LIKE 'otel-gateway-collector-%' AND TimeUnix > now() - INTERVAL 2 MINUTE
           GROUP BY ResourceAttributes['k8s.pod.uid'])"
}
gateways=$(kubectl get statefulset otel-gateway-collector -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
all_receiving() { [ "$(gateways_receiving)" = "$gateways" ]; }
wait_for 180 all_receiving && pass "collectors send to all ${gateways} gateways" \
  || fail "$(gateways_receiving) of ${gateways} gateways receive collector data"
check_rows "cAdvisor: %n container memory points" \
  "SELECT count() FROM otel_metrics_gauge WHERE MetricName = 'container_memory_working_set_bytes'"

exit "$FAILED"
