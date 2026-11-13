#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_kind_context

INSTANCES="pg-alpha:3 pg-beta:2"
RUN=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
SLOW="pg_sleep(0.5)"

hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
psql_on() { PG_CLUSTER="$1" pg_psql -qtA -c "$2" >/dev/null; }
log_rows() { count "SELECT count() FROM otel_logs WHERE ServiceName = 'postgres-server-log' AND position(Body, '$1') > 0"; }

for entry in $INSTANCES; do
  c=${entry%:*} want=${entry#*:}
  ready=$(kubectl get cluster "$PG_NAME" -n "$c" -o jsonpath='{.status.readyInstances}' 2>/dev/null || true)
  [ "${ready:-0}" = "$want" ] && pass "${c}: ${ready} instances ready" || fail "${c}: ${ready:-0} ready, expected ${want}"

  nodes=$(kubectl get pods -n "$c" -l "cnpg.io/cluster=${PG_NAME},cnpg.io/podRole=instance" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u | wc -l | tr -d ' ' || true)
  [ "$nodes" = "$want" ] && pass "${c}: one instance per node" || fail "${c}: instances on ${nodes} nodes"

  vols=$(kubectl get pods -n "$c" -l "cnpg.io/cluster=${PG_NAME},cnpg.io/podRole=instance" -o jsonpath='{.items[0].spec.volumes[*].image.reference}' 2>/dev/null || true)
  grep -q pg-tracing <<< "$vols" && grep -q pg-stat-ch <<< "$vols" \
    && pass "${c}: extensions mounted as image volumes" || fail "${c}: image volumes missing (${vols:-none})"

  exts=$(PG_CLUSTER="$c" pg_psql -tAc "SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension" 2>/dev/null || true)
  [[ "$exts" == *pg_stat_ch*pg_tracing* ]] && pass "${c}: both extensions created" || fail "${c}: extensions '${exts}'"
done

# Below and above log_min_duration_statement.
psql_on pg-beta "SELECT /* fast-${RUN} */ 1"
psql_on pg-beta "SELECT /* slow-${RUN} */ ${SLOW}"

TRACE=$(hex 16)
psql_on pg-alpha "/*traceparent='00-${TRACE}-$(hex 8)-01'*/ SELECT /* traced-${RUN} */ ${SLOW}"

arrived() { [ "$(log_rows "slow-${RUN}")" -ge 1 ] && [ "$(count "SELECT count() FROM otel_traces WHERE TraceId = '${TRACE}'")" -ge 1 ]; }
wait_for 90 arrived || true

[ "$(log_rows "slow-${RUN}")" -ge 1 ] && pass "server log keeps statements above the threshold" || fail "slow statement missing from the server log"
[ "$(log_rows "fast-${RUN}")" = 0 ] && pass "server log skips statements below the threshold" || fail "fast statement logged"

QID=$(count "SELECT any(SpanAttributes['query.query_id']) FROM otel_traces WHERE TraceId = '${TRACE}' AND SpanAttributes['query.query_id'] NOT IN ('', '0')")
[ -n "$QID" ] && [ "$QID" != 0 ] && pass "sampled traceparent traced (query_id ${QID})" || fail "no PostgreSQL span for trace ${TRACE}"
check_rows "query_id ${QID} in pg_stat_ch events (%n)" \
  "SELECT count() FROM otel_logs WHERE ServiceName = 'pg_stat_ch' AND LogAttributes['query_id'] = '${QID}'
     AND ResourceAttributes['k8s.namespace.name'] = 'pg-alpha'"
check_rows "query_id ${QID} in the server log (%n)" \
  "SELECT count() FROM otel_logs WHERE ServiceName = 'postgres-server-log' AND LogAttributes['query_id'] = '${QID}'"

# A statement traced by sampling has no traceparent; drill finds its log line by pod, pid and query_id.
PG_CLUSTER=pg-beta pg_psql -qtA -c "SET pg_tracing.sample_rate = 1" -c "SELECT /* sampled-${RUN} */ ${SLOW}" >/dev/null
SAMPLED=""
sampled() {
  SAMPLED=$(count "SELECT any(TraceId) FROM otel_traces WHERE SpanName LIKE '%sampled-${RUN}%'")
  [ -n "$SAMPLED" ] && [ "$(log_rows "sampled-${RUN}")" -ge 1 ]
}
wait_for 90 sampled || true
drilled=$(TRACE_ID="$SAMPLED" PG_CLUSTER=pg-beta "${ROOT_DIR}/scripts/correlate.sh" drill 2>/dev/null | grep -c '│ log ' || true)
[ "$drilled" -ge 1 ] && pass "drill shows the server log of a sampled trace" || fail "drill found no server log for sampled trace ${SAMPLED:-none}"

# Background processes reach the server log too, not only statements.
psql_on pg-beta "CHECKPOINT"
checkpointed() {
  [ "$(count "SELECT count() FROM otel_logs WHERE ServiceName = 'postgres-server-log'
                AND LogAttributes['backend_type'] = 'checkpointer' AND ResourceAttributes['k8s.namespace.name'] = 'pg-beta'
                AND Timestamp > now() - INTERVAL 2 MINUTE")" -gt 0 ]
}
wait_for 90 checkpointed && pass "checkpointer records in the server log" || fail "no checkpointer records from pg-beta"

POLLUTED=$(count "SELECT count() FROM otel_traces WHERE SpanName LIKE '%traceparent%'")
[ "${POLLUTED:-0}" = 0 ] && pass "no traceparent leaked into span names" || fail "${POLLUTED} span names contain a traceparent"

for c in "${CLUSTERS[@]}"; do
  check_rows "${c}: CNPG metrics (%n points)" \
    "SELECT count() FROM otel_metrics_gauge WHERE MetricName = 'cnpg_collector_up' AND ResourceAttributes['k8s.namespace.name'] = '${c}'"
done

# The agent resumes from stored offsets: lines written while it restarts arrive exactly once.
node=$(kubectl get pods -n pg-beta -l cnpg.io/cluster=${PG_NAME},cnpg.io/instanceRole=primary -o jsonpath='{.items[0].spec.nodeName}')
agent=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=otel-agent-collector --field-selector "spec.nodeName=${node}" -o name)
kubectl delete -n "$NAMESPACE" "$agent" --wait=false >/dev/null
for i in $(seq 1 10); do psql_on pg-beta "SELECT /* restart-${RUN} */ ${SLOW}"; done
ten() { [ "$(log_rows "restart-${RUN}")" -ge 10 ]; }
wait_for 120 ten || true
sleep 15
n=$(log_rows "restart-${RUN}")
[ "$n" = 10 ] && pass "agent restart: 10/10 lines exactly once" || fail "agent restart: ${n} of 10 lines"

# Failover: the new primary keeps reporting under the same namespace.
old=$(kubectl get cluster "$PG_NAME" -n pg-alpha -o jsonpath='{.status.currentPrimary}')
kubectl delete pod -n pg-alpha "$old" --wait=false >/dev/null
# Smart shutdown keeps the old primary up while clients stay connected, so
# currentPrimary moves before the promotion finishes. Wait for the whole cluster.
promoted() {
  local current target ready
  current=$(kubectl get cluster "$PG_NAME" -n pg-alpha -o jsonpath='{.status.currentPrimary}')
  target=$(kubectl get cluster "$PG_NAME" -n pg-alpha -o jsonpath='{.status.targetPrimary}')
  ready=$(kubectl get cluster "$PG_NAME" -n pg-alpha -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  [ -n "$current" ] && [ "$current" != "$old" ] && [ "$current" = "$target" ] && [ "$ready" = True ]
}
wait_for 600 promoted && pass "pg-alpha failed over from ${old} to $(kubectl get cluster "$PG_NAME" -n pg-alpha -o jsonpath='{.status.currentPrimary}')" \
  || fail "pg-alpha did not complete the failover"
wait_for 120 psql_on pg-alpha "SELECT 1" || true
wait_for 300 load_resumed pg-alpha && pass "after failover: HammerDB load resumed" || fail "after failover: HammerDB load did not resume"
TRACE=$(hex 16)
psql_on pg-alpha "/*traceparent='00-${TRACE}-$(hex 8)-01'*/ SELECT /* failover-${RUN} */ ${SLOW}"
after() {
  [ "$(count "SELECT count() FROM otel_traces WHERE TraceId = '${TRACE}' AND ResourceAttributes['k8s.namespace.name'] = 'pg-alpha'")" -ge 1 ] &&
  [ "$(log_rows "failover-${RUN}")" -ge 1 ]
}
wait_for 120 after && pass "after failover: traces and server log from pg-alpha" || fail "after failover: signals missing"

exit "$FAILED"
