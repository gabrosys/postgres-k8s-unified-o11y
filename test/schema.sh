#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_kind_context

TABLES="'otel_traces','otel_traces_trace_id_ts','otel_logs','otel_metrics_gauge','otel_metrics_sum',
        'otel_metrics_histogram','otel_metrics_exponential_histogram','otel_metrics_summary'"

replicated=$(count "SELECT count() FROM clusterAllReplicas('otel', system.tables)
  WHERE database = 'otel' AND name IN (${TABLES}) AND engine = 'ReplicatedMergeTree'")
[ "$replicated" = 16 ] && pass "8 replicated tables on both replicas" \
  || fail "${replicated:-0} replicated tables across replicas, expected 16"

check_rows "trace id materialized view present (%n)" \
  "SELECT count() FROM system.tables WHERE database = 'otel' AND name = 'otel_traces_trace_id_ts_mv'"

ttl() { count "SELECT countIf(create_table_query LIKE '%TTL%toIntervalDay(${2})%') FROM system.tables
                 WHERE database = 'otel' AND name = '$1'"; }
check "$(ttl otel_traces "$(retention TRACES_TTL_DAYS)")" "otel_traces TTL matches the overlay"
check "$(ttl otel_logs "$(retention LOGS_TTL_DAYS)")" "otel_logs TTL matches the overlay"
check "$(ttl otel_metrics_gauge "$(retention METRICS_TTL_DAYS)")" "otel_metrics_gauge TTL matches the overlay"

version() { count "SELECT max(version) FROM otel.schema_migrations"; }
mutations() { count "SELECT count() FROM clusterAllReplicas('otel', system.mutations) WHERE database = 'otel'"; }

v_before=$(version); m_before=$(mutations)
"${ROOT_DIR}/scripts/deploy.sh" >/dev/null
v_after=$(version); m_after=$(mutations)
[ "${v_before:-0}" -gt 0 ] && [ "$v_before" = "$v_after" ] && [ "$m_before" = "$m_after" ] \
  && pass "rerun is a no-op (version ${v_after}, ${m_after} mutations)" \
  || fail "rerun changed state: version ${v_before:-none} -> ${v_after:-none}, mutations ${m_before} -> ${m_after}"

job_complete() {
  [ "$(kubectl get job clickhouse-schema -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}')" = True ]
}
rerun_job() {
  kubectl delete job clickhouse-schema -n "$NAMESPACE" >/dev/null
  kubectl apply -k "${ROOT_DIR}/deploy/overlays/${OVERLAY:-kind}" >/dev/null
}

# DDL that fails on one replica leaves the version dirty; the next attempt must repair it.
latest() { CH_FORMAT=TSV ch_query "SELECT version, dirty FROM otel.schema_migrations ORDER BY sequence DESC LIMIT 1" | tr '\t' ' '; }
v=$(version)
ch_query "INSERT INTO otel.schema_migrations VALUES (${v}, 1, toUnixTimestamp64Nano(now64(9)))"
rerun_job
wait_for 300 job_complete && [ "$(latest)" = "${v} 0" ] && pass "schema Job repairs a dirty version ${v}" \
  || fail "schema Job stuck on a dirty version: $(latest)"

# With a replica down the Job must wait for it rather than finish against the survivor.
trap 'kubectl scale statefulset chi-otel-otel-0-1 -n "$NAMESPACE" --replicas=1 >/dev/null' EXIT
kubectl scale statefulset chi-otel-otel-0-1 -n "$NAMESPACE" --replicas=0 >/dev/null
kubectl wait --for=delete pod/chi-otel-otel-0-1-0 -n "$NAMESPACE" --timeout=120s >/dev/null
rerun_job
sleep 60
waiting=$(kubectl logs -n "$NAMESPACE" job/clickhouse-schema -c database 2>/dev/null | grep -c 'waiting for' || true)
! job_complete && [ "$waiting" -gt 0 ] && pass "schema Job waits while a replica is down (${waiting} polls)" \
  || fail "schema Job did not wait for the missing replica"
kubectl scale statefulset chi-otel-otel-0-1 -n "$NAMESPACE" --replicas=1 >/dev/null
wait_for 600 job_complete && pass "schema Job completes once the replica is back" || fail "schema Job did not complete"
"${ROOT_DIR}/scripts/deploy.sh" >/dev/null && pass "replicas converged after the outage" || fail "replicas did not converge"

exit "$FAILED"
