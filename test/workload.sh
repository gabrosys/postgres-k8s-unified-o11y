#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_kind_context

THRESHOLD_MS=$(kubectl get cluster "$PG_NAME" -n "${CLUSTERS[0]}" \
  -o jsonpath='{.spec.postgresql.parameters.log_min_duration_statement}')
TARGET="${CLUSTERS[0]}"
NEW_ORDER="prepare neword%"

# shape_p50 NAMESPACE LIKE MINUTES: median duration in ms of one statement shape.
shape_p50() {
  count "SELECT round(quantile(0.5)(toFloat64OrZero(LogAttributes['duration_us'])) / 1000)
         FROM otel_logs WHERE ServiceName = 'pg_stat_ch' AND ResourceAttributes['k8s.namespace.name'] = '$1'
           AND LogAttributes['db.query.text'] LIKE '$2' AND Timestamp > now() - INTERVAL $3 MINUTE"
}
shape_qid() {
  count "SELECT any(LogAttributes['query_id']) FROM otel_logs WHERE ServiceName = 'pg_stat_ch'
         AND ResourceAttributes['k8s.namespace.name'] = '$1' AND LogAttributes['db.query.text'] LIKE '$2'
         AND Timestamp > now() - INTERVAL $3 MINUTE"
}

for c in "${CLUSTERS[@]}"; do
  kubectl rollout status deployment/hammerdb -n "$c" --timeout=180s >/dev/null 2>&1 \
    && pass "${c}: HammerDB running" || fail "${c}: HammerDB not ready"
  ware=$(PG_CLUSTER="$c" pg_psql -tAc "SELECT count(*) FROM warehouse" 2>/dev/null || echo 0)
  [ "$ware" = 4 ] && pass "${c}: TPROC-C schema with 4 warehouses" || fail "${c}: ${ware} warehouses"
  check_rows "${c}: %n New-Order events in the last 5 minutes" \
    "SELECT count() FROM otel_logs WHERE ServiceName = 'pg_stat_ch' AND ResourceAttributes['k8s.namespace.name'] = '${c}'
       AND LogAttributes['db.query.text'] LIKE '%neword%' AND Timestamp > now() - INTERVAL 5 MINUTE"
  check_rows "${c}: %n sampled PostgreSQL traces in the last 5 minutes" \
    "SELECT uniqExact(TraceId) FROM otel_traces WHERE ServiceName = 'PostgreSQL_Server'
       AND ResourceAttributes['k8s.namespace.name'] = '${c}' AND Timestamp > now() - INTERVAL 5 MINUTE"
done

# A cluster that just failed over is still rebuilding a replica; wait for a steady rate.
steady() {
  [ "$(count "SELECT anyIf(n, m = toStartOfMinute(now()) - INTERVAL 1 MINUTE) >= 0.8 * avg(n) FROM (
             SELECT toStartOfMinute(Timestamp) m, count() n FROM otel_logs
             WHERE ServiceName = 'pg_stat_ch' AND ResourceAttributes['k8s.namespace.name'] = '${TARGET}'
               AND Timestamp >= toStartOfMinute(now()) - INTERVAL 6 MINUTE AND Timestamp < toStartOfMinute(now())
             GROUP BY m)")" = 1 ]
}
cluster_ready() { [ "$(kubectl get cluster "$PG_NAME" -n "$TARGET" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]; }
wait_for 600 cluster_ready || true
wait_for 600 steady && pass "${TARGET}: steady statement rate" || fail "${TARGET}: statement rate not steady"

healthy=$(shape_p50 "$TARGET" "$NEW_ORDER" 5)
[ -n "$healthy" ] && [ "$healthy" -lt "$THRESHOLD_MS" ] && pass "healthy New-Order p50 ${healthy} ms below the ${THRESHOLD_MS} ms threshold" \
  || fail "healthy New-Order p50 ${healthy:-?} ms not below ${THRESHOLD_MS} ms"
QID=$(shape_qid "$TARGET" "$NEW_ORDER" 5)

# The demo's regression: a planner override reaches the cluster, then is removed.
trap '"${ROOT_DIR}/scripts/chaos-restore.sh" >/dev/null 2>&1 || true' EXIT
"${ROOT_DIR}/scripts/chaos-degrade.sh" >/dev/null
sleep 150

degraded=$(shape_p50 "$TARGET" "$NEW_ORDER" 2)
[ -n "$degraded" ] && [ "$degraded" -gt "$THRESHOLD_MS" ] && pass "regressed New-Order p50 ${degraded} ms crosses the threshold" \
  || fail "regressed New-Order p50 ${degraded:-?} ms does not cross ${THRESHOLD_MS} ms"
[ "$(shape_qid "$TARGET" "$NEW_ORDER" 2)" = "$QID" ] && pass "New-Order query_id ${QID} survives the plan change" \
  || fail "New-Order query_id changed with the plan"
check_rows "regressed statements in the server log (%n)" \
  "SELECT count() FROM otel_logs WHERE ServiceName = 'postgres-server-log'
     AND ResourceAttributes['k8s.namespace.name'] = '${TARGET}' AND Timestamp > now() - INTERVAL 2 MINUTE"

"${ROOT_DIR}/scripts/chaos-restore.sh" >/dev/null
trap - EXIT
[ "$(PG_CLUSTER="$TARGET" pg_psql -tAc "SHOW enable_indexscan")" = on ] \
  && pass "${TARGET}: planner override removed" || fail "${TARGET}: enable_indexscan still off"

# A restarted pod keeps the data: its init container sees the schema and skips the build.
kubectl rollout restart deployment/hammerdb -n "$TARGET" >/dev/null
kubectl rollout status deployment/hammerdb -n "$TARGET" --timeout=300s >/dev/null
kubectl logs -n "$TARGET" deployment/hammerdb -c schema 2>/dev/null | grep -q 'schema present' \
  && pass "restarted HammerDB skips the schema build" || fail "restarted HammerDB rebuilt the schema"

# An interrupted build leaves tables without the final functions; the next start rebuilds cleanly.
PG_CLUSTER="$TARGET" pg_psql -qc "DROP FUNCTION slev" >/dev/null
kubectl rollout restart deployment/hammerdb -n "$TARGET" >/dev/null
kubectl rollout status deployment/hammerdb -n "$TARGET" --timeout=600s >/dev/null \
  && [ "$(PG_CLUSTER="$TARGET" pg_psql -tAc "SELECT count(*) FROM warehouse")" = 4 ] \
  && [ "$(PG_CLUSTER="$TARGET" pg_psql -tAc "SELECT count(*) FROM pg_proc WHERE proname = 'slev'")" = 1 ] \
  && pass "partial schema rebuilt from scratch" || fail "partial schema not recovered"

exit "$FAILED"
