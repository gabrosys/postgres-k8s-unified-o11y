#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_kind_context

APP_NS=pg-alpha
SCAN_PATTERN='^(\\w+)(?: using \\w+)? on order_line'
SEQ_NODE=SeqScan
INDEX_NODE=IndexOnlyScan

for d in checkout checkout-load; do
  kubectl rollout status "deployment/${d}" -n "$APP_NS" --timeout=180s >/dev/null 2>&1 \
    && pass "${d} available" || fail "${d} not available"
done

# post_checkout: one request from inside the cluster; prints the X-Trace-Id header.
post_checkout() {
  kubectl exec -n "$APP_NS" deploy/checkout-load -- \
    curl -si -X POST --max-time 10 http://checkout:8080/checkout 2>/dev/null \
    | tr -d '\r' | awk -F': ' 'tolower($1) == "x-trace-id" { print $2 }'
}

TRACE=$(post_checkout || true)
[[ "$TRACE" =~ ^[0-9a-f]{32}$ ]] && pass "POST /checkout returns trace ${TRACE}" || fail "no X-Trace-Id header (${TRACE:-empty})"

nested() {
  [ "$(count "SELECT count() FROM otel_traces pg JOIN otel_traces client
                ON pg.ParentSpanId = client.SpanId AND pg.TraceId = client.TraceId
              WHERE pg.TraceId = '${TRACE}' AND client.TraceId = '${TRACE}'
                AND pg.ServiceName = 'PostgreSQL_Server' AND client.ServiceName = 'checkout'
                AND client.SpanKind = 'Client'")" -gt 0 ]
}
server_span() {
  [ "$(count "SELECT count() FROM otel_traces WHERE TraceId = '${TRACE}'
              AND ServiceName = 'checkout' AND SpanKind = 'Server'")" -gt 0 ]
}
wait_for 60 server_span && pass "trace has a checkout server span" || fail "no checkout server span for ${TRACE}"
wait_for 60 nested && pass "PostgreSQL spans nest under checkout client spans" || fail "no PostgreSQL span under a checkout client span"

check_rows "%n checkout traces in the last 5 minutes" \
  "SELECT uniqExact(TraceId) FROM otel_traces WHERE ServiceName = 'checkout' AND Timestamp > now() - INTERVAL 5 MINUTE"

QID=$(count "SELECT argMax(SpanAttributes['query.query_id'], Timestamp) FROM otel_traces
             WHERE ServiceName = 'PostgreSQL_Server' AND SpanName LIKE 'SELECT count(*) FROM order_line WHERE ol_i_id%'
               AND Timestamp > now() - INTERVAL 2 MINUTE
               AND TraceId IN (SELECT TraceId FROM otel_traces WHERE ServiceName = 'checkout'
                                 AND Timestamp > now() - INTERVAL 2 MINUTE)")
[ -n "$QID" ] && [ "$QID" != 0 ] && pass "incident statement query_id ${QID}" || fail "no query_id for the order_line lookup"

THRESHOLD_MS=$(kubectl get cluster "$PG_NAME" -n "$APP_NS" \
  -o jsonpath='{.spec.postgresql.parameters.log_min_duration_statement}')

# qid_p50 MINUTES: median duration in ms of the incident statement.
qid_p50() {
  count "SELECT round(quantile(0.5)(toFloat64OrZero(LogAttributes['duration_us'])) / 1000)
         FROM otel_logs WHERE ServiceName = 'pg_stat_ch' AND LogAttributes['query_id'] = '${QID}'
           AND Timestamp > now() - INTERVAL $1 MINUTE"
}
# plan_nodes SINCE: distinct executor node kinds under the incident statement since SINCE.
plan_nodes() {
  CH_FORMAT=TSV ch_query "SELECT arrayStringConcat(groupUniqArray(node), ',') FROM (
      SELECT extract(SpanName, '${SCAN_PATTERN}') AS node FROM otel_traces
      WHERE ServiceName = 'PostgreSQL_Server' AND Timestamp > '$1'
        AND TraceId IN (SELECT TraceId FROM otel_traces WHERE ServiceName = 'PostgreSQL_Server'
                          AND SpanAttributes['query.query_id'] = '${QID}' AND Timestamp > '$1')
        AND node != '')"
}
now_ts() { CH_FORMAT=TSV ch_query "SELECT toString(now())"; }
# index_oid: OID of a valid checkout_ol_item, empty when it is missing or invalid.
index_oid() {
  PG_CLUSTER="$APP_NS" pg_psql -tAc "SELECT c.oid FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid
                                      WHERE c.relname = 'checkout_ol_item' AND i.indisvalid"
}
index_exists() { [ -n "$(index_oid)" ]; }
restart_checkout() {
  kubectl rollout restart deployment/checkout -n "$APP_NS" >/dev/null
  kubectl rollout status deployment/checkout -n "$APP_NS" --timeout=600s >/dev/null
}

trap '"${ROOT_DIR}/scripts/incident.sh" 3 >/dev/null 2>&1 || true' EXIT

# Start from the healthy release and measure only executions made with the index in place.
# The restart reapplies its migration: a HammerDB schema rebuild drops checkout's objects too.
"${ROOT_DIR}/scripts/incident.sh" 3 >/dev/null
restart_checkout
index_exists || fail "healthy release has no checkout_ol_item"
sleep 60
healthy=$(qid_p50 1)
[ -n "$healthy" ] && [ "$healthy" -lt "$THRESHOLD_MS" ] \
  && pass "healthy item_history p50 ${healthy} ms below ${THRESHOLD_MS} ms" || fail "healthy p50 ${healthy:-?} ms not below ${THRESHOLD_MS} ms"

"${ROOT_DIR}/scripts/incident.sh" 2 >/dev/null
index_exists && fail "v2 migration left checkout_ol_item in place" || pass "v2 migration dropped checkout_ol_item"
since=$(now_ts)
sleep 120
degraded=$(qid_p50 1)
base=$(( healthy > 1 ? healthy : 1 ))
[ -n "$degraded" ] && [ "$degraded" -ge 10 ] && [ "$degraded" -ge $(( 10 * base )) ] \
  && pass "v2 item_history p50 ${degraded} ms, at least 10x the healthy ${healthy} ms" || fail "v2 p50 ${degraded:-?} ms is not 10x the healthy ${healthy} ms"
slow=$(count "SELECT count() FROM otel_logs WHERE ServiceName = 'postgres-server-log'
              AND LogAttributes['query_id'] = '${QID}' AND Timestamp > '${since}'")
check "$slow" "v2: ${slow} slow item_history calls in the server log"
nodes=$(plan_nodes "$since")
[[ "$nodes" == *"${SEQ_NODE}"* && "$nodes" != *"${INDEX_NODE}"* ]] \
  && pass "v2 plan: ${nodes}" || fail "v2 plan nodes '${nodes}', want ${SEQ_NODE} without ${INDEX_NODE}"

"${ROOT_DIR}/scripts/incident.sh" 3 >/dev/null
index_exists && pass "v3 migration recreated checkout_ol_item" || fail "v3 migration did not recreate checkout_ol_item"
since=$(now_ts)
sleep 90
nodes=$(plan_nodes "$since")
[[ "$nodes" == *"${INDEX_NODE}"* && "$nodes" != *"${SEQ_NODE}"* ]] \
  && pass "v3 plan: ${nodes}" || fail "v3 plan nodes '${nodes}', want ${INDEX_NODE} without ${SEQ_NODE}"
after=$(count "SELECT count() FROM otel_logs WHERE ServiceName = 'pg_stat_ch'
               AND LogAttributes['query_id'] = '${QID}' AND Timestamp > '${since}'")
check "$after" "same query_id ${QID} before, during and after the incident"

"${ROOT_DIR}/scripts/deploy.sh" >/dev/null
[ "$(kubectl get deploy checkout -n "$APP_NS" -o jsonpath='{.spec.template.spec.initContainers[0].env[?(@.name=="APP_VERSION")].value}')" = 3 ] \
  && index_exists && pass "make deploy keeps APP_VERSION=3 and the index" || fail "make deploy reset the incident state"

oid=$(index_oid)
restart_checkout
[ -n "$oid" ] && [ "$(index_oid)" = "$oid" ] && pass "a checkout restart at v3 keeps the same index" \
  || fail "a checkout restart at v3 rebuilt checkout_ol_item (${oid:-none} -> $(index_oid))"

PG_CLUSTER="$APP_NS" pg_psql -qc "UPDATE pg_index SET indisvalid = false WHERE indexrelid = 'checkout_ol_item'::regclass"
restart_checkout
index_exists && pass "a restart replaces an invalid checkout_ol_item" || fail "an invalid checkout_ol_item survived a restart"

old=$(kubectl get cluster "$PG_NAME" -n "$APP_NS" -o jsonpath='{.status.currentPrimary}')
kubectl delete pod -n "$APP_NS" "$old" --wait=false >/dev/null
promoted() {
  local p
  p=$(kubectl get cluster "$PG_NAME" -n "$APP_NS" -o jsonpath='{.status.currentPrimary}')
  [ -n "$p" ] && [ "$p" != "$old" ]
}
wait_for 600 promoted && pass "pg-alpha failed over from ${old}" || fail "pg-alpha did not fail over"
since=$(now_ts)
fresh() { [ "$(count "SELECT count() FROM otel_traces WHERE ServiceName = 'checkout' AND Timestamp > '${since}'")" -gt 0 ]; }
wait_for 180 fresh && pass "checkout traces resume after failover" || fail "no checkout traces after failover"

exit "$FAILED"
