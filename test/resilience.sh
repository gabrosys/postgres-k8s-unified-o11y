#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_kind_context

GATEWAY=otel-gateway-collector
OUTAGE_S="${OUTAGE_S:-180}"
pod="ResourceAttributes['k8s.pod.name']"
uid="ResourceAttributes['k8s.pod.uid']"
# Flag 1 marks the staleness sample written when a target disappears; its value is 0.
sample="bitAnd(Flags, 1) = 0"

restore_clickhouse() { kubectl patch chi otel -n "$NAMESPACE" --type=merge -p '{"spec":{"stop":"no"}}' >/dev/null; }
trap restore_clickhouse EXIT

# A partial batch waits up to flush_timeout in the queue; anything below a full batch is drained.
BATCH=$(kubectl get otelcol otel-gateway -n "$NAMESPACE" -o jsonpath='{.spec.config.exporters.clickhouse.sending_queue.batch.min_size}')
GATEWAYS=$(kubectl get statefulset "$GATEWAY" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
LIMIT=$(kubectl get statefulset "$GATEWAY" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}')
case "$LIMIT" in
  *Gi) LIMIT_BYTES=$(( ${LIMIT%Gi} << 30 )) ;;
  *Mi) LIMIT_BYTES=$(( ${LIMIT%Mi} << 20 )) ;;
  *) echo "error: unsupported memory limit ${LIMIT}" >&2; exit 1 ;;
esac
HOSTS=$(kubectl get chi otel -n "$NAMESPACE" -o jsonpath='{.status.hosts}')

now() { date +%s; }

# busiest METRIC POD_LIKE: pod with the largest METRIC increase over the last 2 minutes.
busiest() {
  CH_FORMAT=TSV ch_query "SELECT ${pod} p FROM otel_metrics_sum WHERE MetricName = '$1' AND p LIKE '$2' AND ${sample}
    AND TimeUnix > now() - INTERVAL 2 MINUTE GROUP BY p, ${uid} ORDER BY max(Value) - min(Value) DESC LIMIT 1"
}

# replace POD: deletes POD and waits for its replacement to be Ready.
replace() {
  local old
  old=$(kubectl get pod "$1" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')
  kubectl delete pod "$1" -n "$NAMESPACE" --wait=false >/dev/null
  replaced() {
    [ "$(kubectl get pod "$1" -n "$NAMESPACE" -o jsonpath='{.metadata.uid} {.status.conditions[?(@.type=="Ready")].status}')" != "${old} True" ] \
      && [ "$(kubectl get pod "$1" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]
  }
  wait_for 600 replaced "$1"
}

# drained SINCE: every gateway queue reported after SINCE holds less than one batch.
drained() {
  [ "$(count "SELECT countIf(v < ${BATCH}) = ${GATEWAYS} * 3 AND count() = ${GATEWAYS} * 3 FROM (
             SELECT argMax(Value, TimeUnix) v FROM otel_metrics_gauge WHERE MetricName = 'otelcol_exporter_queue_size'
             AND ${pod} LIKE '${GATEWAY}-%' AND ${sample} AND TimeUnix > toDateTime($1) GROUP BY ${pod}, Attributes['data_type'])")" = 1 ]
}

# Counter increase per pod incarnation between the last sample before FROM and the last before TO.
increase() {
  echo "SELECT ${uid} AS u, max(Value) - argMaxIf(Value, TimeUnix, TimeUnix < toDateTime($2)) AS d,
               maxIf(TimeUnix, TimeUnix < toDateTime($2)) AS b, max(TimeUnix) AS e
        FROM otel_metrics_sum WHERE MetricName LIKE '$1' AND ${sample}
          AND TimeUnix BETWEEN toDateTime($2) - INTERVAL 2 MINUTE AND toDateTime($3) GROUP BY u, MetricName, Attributes"
}

# accounting LABEL FROM TO: no send failures, and every span the gateways accepted is stored.
accounting() {
  local failed accepted stored
  failed=$(count "SELECT sum(d) FROM ($(increase 'otelcol_exporter_send_failed_%' "$2" "$3"))")
  [ "${failed:-0}" = 0 ] && pass "$1: no exporter send failures" || fail "$1: ${failed} items failed to send"

  read -r accepted stored < <(CH_FORMAT=TSV ch_query "
    WITH a AS ($(increase otelcol_receiver_accepted_spans "$2" "$3"))
    SELECT (SELECT sum(d) FROM a), uniqExact(TraceId, SpanId) FROM otel_traces
    WHERE Timestamp BETWEEN (SELECT minIf(b, b > toDateTime(0)) FROM a) - INTERVAL 10 SECOND AND (SELECT max(e) FROM a)")
  [ "${accepted:-0}" -gt 0 ] && [ "$stored" -ge "$accepted" ] \
    && pass "$1: ${stored} spans stored >= ${accepted} accepted by the gateways" \
    || fail "$1: ${stored} spans stored < ${accepted} accepted by the gateways"
}

# pg_tracing_info COLUMN: COLUMN summed over every PostgreSQL instance.
pg_tracing_info() {
  local c p total=0 n
  for c in "${CLUSTERS[@]}"; do
    for p in $(kubectl get pods -n "$c" -l "cnpg.io/cluster=${PG_NAME}" -o name); do
      n=$(kubectl exec -n "$c" "$p" -c postgres -- psql -U postgres -d "$DATABASE" -tAc "SELECT $1 FROM pg_tracing_info()" 2>/dev/null)
      total=$((total + ${n:-0}))
    done
  done
  echo "$total"
}

# delivered LABEL FROM SENT_FROM TO SENT_TO: every span pg_tracing got a 2xx for between FROM and TO is stored.
delivered() {
  local stored sent=$(( $5 - $3 ))
  stored=$(count "SELECT uniqExact(TraceId, SpanId) FROM otel_traces
                  WHERE Timestamp BETWEEN toDateTime($2) - INTERVAL 5 SECOND AND toDateTime($4)")
  [ "$sent" -gt 0 ] && [ "$stored" -ge "$sent" ] && pass "$1: ${stored} spans stored >= ${sent} sent by pg_tracing" \
    || fail "$1: ${stored} spans stored < ${sent} sent by pg_tracing"
}

echo "== gateway and ClickHouse replica restart under load"
gw=$(busiest otelcol_receiver_accepted_spans "${GATEWAY}-%")
ch=$(busiest ClickHouseProfileEvents_InsertQuery 'chi-otel-%')
failures=$(pg_tracing_info otel_failures)
sent=$(pg_tracing_info otel_sent_spans)
t0=$(now)
replace "$gw" & gw_job=$!
replace "$ch" && wait "$gw_job" && pass "${gw} and ${ch} replaced and Ready" || fail "${gw} or ${ch} not Ready again"
t_up=$(now)
sent1=$(pg_tracing_info otel_sent_spans)
wait_for 300 drained "$t_up" && pass "gateway queues drained" || fail "gateway queues still hold a batch or more"
sleep 60
accounting "restart" "$t0" "$(now)"
delivered "restart" "$t0" "$sent" "$t_up" "$sent1"
echo "  pg_tracing export failures during the restart: $(( $(pg_tracing_info otel_failures) - failures ))"

echo "== ClickHouse stopped for ${OUTAGE_S}s"
restarts=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name="$GATEWAY" -o jsonpath='{range .items[*]}{.metadata.uid}:{.status.containerStatuses[0].restartCount} {end}')
failures=$(pg_tracing_info otel_failures)
sent=$(pg_tracing_info otel_sent_spans)
t0=$(now)
kubectl patch chi otel -n "$NAMESPACE" --type=merge -p '{"spec":{"stop":"yes"}}' >/dev/null
stopped() { [ -z "$(kubectl get pods -n "$NAMESPACE" -l clickhouse.altinity.com/chi=otel -o name)" ]; }
wait_for 300 stopped && pass "ClickHouse stopped" || fail "ClickHouse pods still running"
sleep "$OUTAGE_S"
t_down=$(now)
restore_clickhouse
ready() {
  [ "$(kubectl get pods -n "$NAMESPACE" -l clickhouse.altinity.com/chi=otel \
        -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -c True)" = "$HOSTS" ]
}
wait_for 600 ready && pass "ClickHouse back" || { fail "ClickHouse not Ready"; exit 1; }
t_up=$(now)
sent1=$(pg_tracing_info otel_sent_spans)
wait_for 900 drained "$t_up" && pass "gateway queues drained" || fail "gateway queues still hold a batch or more"
sleep 60
t1=$(now)

peak=$(count "SELECT max(Value) FROM otel_metrics_gauge WHERE MetricName = 'otelcol_exporter_queue_size'
              AND ${pod} LIKE '${GATEWAY}-%' AND ${sample} AND TimeUnix BETWEEN toDateTime(${t0}) AND toDateTime(${t_up})")
[ "${peak%.*}" -ge "$BATCH" ] && pass "queue grew to ${peak%.*} items while ClickHouse was down" \
  || fail "queue peaked at ${peak:-0} items while ClickHouse was down"

memory=$(count "SELECT max(Value) FROM otel_metrics_gauge WHERE MetricName = 'container_memory_working_set_bytes'
                AND Attributes['pod'] LIKE '${GATEWAY}-%' AND Attributes['container'] = 'otc-container' AND ${sample}
                AND TimeUnix BETWEEN toDateTime(${t0}) AND toDateTime(${t1})")
[ "${memory%.*}" -gt 0 ] && [ "${memory%.*}" -lt "$LIMIT_BYTES" ] \
  && pass "gateway memory peaked at $(( ${memory%.*} / 1048576 ))Mi of ${LIMIT}" \
  || fail "gateway memory ${memory:-unknown} against limit ${LIMIT}"
[ "$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name="$GATEWAY" -o jsonpath='{range .items[*]}{.metadata.uid}:{.status.containerStatuses[0].restartCount} {end}')" = "$restarts" ] \
  && pass "no gateway restarted or replaced" || fail "a gateway restarted or was replaced during the outage"

accounting "outage" "$t0" "$t1"
delivered "outage" "$t0" "$sent" "$t_up" "$sent1"
echo "  pg_tracing export failures during the outage: $(( $(pg_tracing_info otel_failures) - failures ))"
echo "  ClickHouse down $(( t_down - t0 ))s, Ready again after $(( t_up - t_down ))s"

exit "$FAILED"
