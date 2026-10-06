#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_env.sh"
require_kind_context
source "${SCRIPT_DIR}/_pg-env.sh"
source "${SCRIPT_DIR}/_ch-env.sh"

FAILED=0
pass() { printf "${GREEN}[PASS]${NC} %s\n" "$1"; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$1"; FAILED=1; }
count() { ch_query "$1" 2>/dev/null | tr -d '[:space:]' || echo 0; }
check() { [ "${1:-0}" -gt 0 ] && pass "$2" || fail "$2"; }

# check_rows LABEL SQL: passes when SQL returns a positive count; %n in LABEL is the count.
check_rows() {
  local n
  n=$(count "$2")
  check "$n" "${1//%n/$n}"
}

# Distinct query ids seen in traces, or in logs (optionally for one ServiceName).
trace_qids() {
  echo "(SELECT DISTINCT SpanAttributes['query.query_id'] AS qid FROM otel_traces
     WHERE SpanAttributes['query.query_id'] NOT IN ('','0') ${1:+AND $1})"
}
log_qids() {
  echo "(SELECT DISTINCT LogAttributes['query_id'] AS qid FROM otel_logs
     WHERE LogAttributes['query_id'] NOT IN ('','0') ${1:+AND ServiceName = '$1'})"
}

for c in "${CLUSTERS[@]}"; do
  exts=$(PG_CLUSTER="$c" pg_psql -tAc "SELECT extname FROM pg_extension")
  grep -qx pg_tracing <<< "$exts" && grep -qx pg_stat_ch <<< "$exts" \
    && pass "${c}: both extensions installed" \
    || fail "${c}: extensions missing"
done

# otel does not exist until the exporter's first write.
if [ "$(CH_DATABASE=default ch_query 'SELECT 1' 2>/dev/null | tr -d '[:space:]')" = "1" ]; then
  pass "ClickHouse reachable"
else
  fail "ClickHouse unreachable"; exit 1
fi

for c in "${CLUSTERS[@]}"; do
  PG_CLUSTER="$c" pg_psql -q -o /dev/null <<'SQL'
SET pg_tracing.sample_rate = 1.0;
DROP TABLE IF EXISTS smoke;
CREATE TABLE smoke (id int primary key, payload text);
INSERT INTO smoke SELECT g, md5(g::text) FROM generate_series(1, 5000) g;
ANALYZE smoke;
SELECT count(*) FROM smoke WHERE payload LIKE 'a%';
SELECT s1.id FROM smoke s1 JOIN smoke s2 ON s1.id = s2.id WHERE s1.id < 500;
-- Force a checkpoint so the checkpointer log record exists.
CHECKPOINT;
SQL
done

# pg_tracing naptime, pg_stat_ch flush, collector batch, cadvisor interval.
sleep 45

check_rows "otel_traces: %n rows" "SELECT count() FROM otel_traces"
check_rows "otel_logs: %n rows" "SELECT count() FROM otel_logs"

check_rows "%n query_id(s) join across otel_traces and otel_logs" \
  "SELECT count() FROM $(trace_qids) t INNER JOIN $(log_qids) l USING (qid)"

check_rows "cnpg_collector_up present (%n points)" \
  "SELECT count() FROM otel_metrics_gauge WHERE MetricName = 'cnpg_collector_up' AND Value = 1"

expect_namespaces() {
  local n
  n=$(count "$2")
  [ "${n:-0}" -ge "${#CLUSTERS[@]}" ] \
    && pass "$1 from ${n} namespaces" \
    || fail "$1 from ${n} namespaces, expected ${#CLUSTERS[@]}"
}
expect_namespaces "CNPG metrics" "
  SELECT uniqExact(ResourceAttributes['k8s.namespace.name'])
  FROM otel_metrics_gauge WHERE MetricName LIKE 'cnpg_%'"

check_rows "cAdvisor memory metrics present (%n points)" \
  "SELECT count() FROM otel_metrics_gauge WHERE MetricName = 'container_memory_working_set_bytes'"

check_rows "server log: %n records" \
  "SELECT count() FROM otel_logs WHERE ServiceName = 'postgres-server-log'"
check_rows "checkpointer records present (%n)" \
  "SELECT count() FROM otel_logs
   WHERE ServiceName = 'postgres-server-log' AND LogAttributes['backend_type'] = 'checkpointer'"
expect_namespaces "server log" "
  SELECT uniqExact(ResourceAttributes['k8s.namespace.name'])
  FROM otel_logs WHERE ServiceName = 'postgres-server-log'"

check_rows "%n query_id(s) present in traces, events AND server log" \
  "SELECT count() FROM $(trace_qids) t
   INNER JOIN $(log_qids pg_stat_ch) e USING (qid)
   INNER JOIN $(log_qids postgres-server-log) s USING (qid)"

check_rows "pgload spans present (%n)" \
  "SELECT count() FROM otel_traces WHERE ServiceName = 'pgload'"

check_rows "%n trace(s) span both pgload and PostgreSQL" "
  SELECT count() FROM
    (SELECT TraceId FROM otel_traces GROUP BY TraceId
       HAVING countIf(ServiceName = 'pgload') > 0
          AND countIf(ServiceName = 'PostgreSQL_Server') > 0)"

check_rows "%n PostgreSQL root span(s) parented by a pgload span" "
  SELECT count() FROM otel_traces AS pg
  INNER JOIN (SELECT SpanId FROM otel_traces WHERE ServiceName = 'pgload') AS app
    ON pg.ParentSpanId = app.SpanId
  WHERE pg.ServiceName = 'PostgreSQL_Server'"

# A trailing sqlcomment would leak the traceparent into the normalized query.
POLLUTED=$(count "SELECT count() FROM otel_traces WHERE SpanName LIKE '%traceparent%'")
[ "${POLLUTED:-0}" -eq 0 ] \
  && pass "no traceparent leaked into span names" \
  || fail "${POLLUTED} span name(s) contain a traceparent"

check_rows "%n app query_id(s) in traces, events AND server log" \
  "SELECT count() FROM $(trace_qids "TraceId IN (SELECT TraceId FROM otel_traces WHERE ServiceName = 'pgload')") t
   INNER JOIN $(log_qids pg_stat_ch) e USING (qid)
   INNER JOIN $(log_qids postgres-server-log) s USING (qid)"

LOOKUP="SELECT id, kind, amount FROM pgload_events WHERE ext_id = 'ext-1'"

for c in "${CLUSTERS[@]}"; do
  IDX=$(PG_CLUSTER="$c" pg_psql -tAc "SELECT count(*) FROM pg_indexes
    WHERE tablename = 'pgload_events' AND indexname = 'pgload_events_ext_id_idx'" | tr -d '[:space:]')
  check "$IDX" "${c}: lookup index present"

  PLAN=$(PG_CLUSTER="$c" pg_psql -tAc "EXPLAIN (COSTS OFF) ${LOOKUP}" | grep -c 'Index Scan' || true)
  check "$PLAN" "${c}: lookup plans as an Index Scan"
done

# The plan changes; the query_id must not.
TARGET="${CLUSTERS[0]}"
qid() { PG_CLUSTER="$TARGET" pg_psql -tAc "EXPLAIN (VERBOSE, COSTS OFF) ${LOOKUP}" \
          | { grep -i 'query identifier' || true; } | tr -dc '0-9-'; }
restore_index() {
  PG_CLUSTER="$TARGET" pg_psql -q -c "CREATE INDEX IF NOT EXISTS pgload_events_ext_id_idx
    ON pgload_events (ext_id); ANALYZE pgload_events" || true
}

trap restore_index EXIT
QID_BEFORE=$(qid)
PG_CLUSTER="$TARGET" pg_psql -q -c "DROP INDEX IF EXISTS pgload_events_ext_id_idx"
QID_AFTER=$(qid)
restore_index
trap - EXIT

[ -n "$QID_BEFORE" ] && [ "$QID_BEFORE" = "$QID_AFTER" ] \
  && pass "query_id ${QID_BEFORE} survives the plan change" \
  || fail "query_id changed with the plan: ${QID_BEFORE:-none} -> ${QID_AFTER:-none}"

if [ "$FAILED" -eq 0 ]; then
  ch_query "
    SELECT ResourceAttributes['k8s.namespace.name'] AS namespace,
           uniqExact(ResourceAttributes['k8s.pod.name']) AS pods,
           count() AS points
    FROM otel_metrics_gauge
    WHERE MetricName LIKE 'cnpg_%'
    GROUP BY namespace ORDER BY namespace
    FORMAT PrettyCompactMonoBlock"
fi

GRAFANA="http://localhost:3000"
DB_STATE=$(curl -sf --max-time 10 "${GRAFANA}/api/health" 2>/dev/null \
  | tr -d ' "' | grep -o 'database:[a-z]*' | cut -d: -f2 || true)
[ "$DB_STATE" = "ok" ] && pass "Grafana healthy at ${GRAFANA}" || fail "Grafana unhealthy"

DS_OK=$(curl -sf --max-time 20 "${GRAFANA}/api/datasources/uid/clickhouse/health" 2>/dev/null \
  | tr -d ' "' | grep -o 'status:[A-Za-z]*' | cut -d: -f2 || true)
[ "$DS_OK" = "OK" ] && pass "Grafana reaches ClickHouse" || fail "datasource health: ${DS_OK:-unreachable}"

DASH=$(curl -sf --max-time 10 "${GRAFANA}/api/search?query=PostgreSQL" 2>/dev/null \
  | grep -c 'pg-unified-o11y' || true)
check "$DASH" "dashboard provisioned"

exit "$FAILED"
