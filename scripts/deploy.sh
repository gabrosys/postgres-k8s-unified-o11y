#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
require_kind_context

OVERLAY="${OVERLAY:-kind}"

# A Job's pod template is immutable; the schema Job is recreated on every deploy.
kubectl delete job clickhouse-schema -n "$NAMESPACE" --ignore-not-found
kubectl apply -k "${ROOT_DIR}/deploy/overlays/${OVERLAY}"

# The Altinity operator reports progress in status.status and keeps the last
# reconciled spec in status.normalizedCompleted, or for a CHI in the
# <kind>-storage-<name> ConfigMap. Its generation tells a fresh Completed from
# the previous one.
completed_generation() {
  local kind="$1" name="$2" gen
  gen=$(kubectl get "$kind" "$name" -n "$NAMESPACE" -o jsonpath='{.status.normalizedCompleted.metadata.generation}')
  [ -n "$gen" ] || gen=$(kubectl get configmap "${kind}-storage-${name}" -n "$NAMESPACE" \
    -o jsonpath='{.data.status-normalizedCompleted}' 2>/dev/null | jq -r '.metadata.generation // empty')
  echo "$gen"
}

wait_completed() {
  local kind="$1" name="$2" deadline=$((SECONDS + 600)) state="" want
  until [ "$state" = "Completed ${want:-}" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "error: ${kind}/${name} is '${state}', want 'Completed ${want}' after 600s" >&2; exit 1; }
    [ -z "$state" ] || sleep 5
    want=$(kubectl get "$kind" "$name" -n "$NAMESPACE" -o jsonpath='{.metadata.generation}')
    state="$(kubectl get "$kind" "$name" -n "$NAMESPACE" -o jsonpath='{.status.status}') $(completed_generation "$kind" "$name")"
  done
  echo "${kind}/${name} Completed (generation ${want})"
}

# Completed does not mean every host has joined the cluster: the schema Job can run
# against one replica and the operator copies tables to the other afterwards.
wait_replicas_converged() {
  local hosts deadline=$((SECONDS + 600)) state=""
  hosts=$(kubectl get chi otel -n "$NAMESPACE" -o jsonpath='{.status.hosts}')
  until [ "$state" = "${hosts} 1" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "error: replicas not converged (${state})" >&2; exit 1; }
    sleep 5
    state=$(CH_DATABASE=default ch_query "
      SELECT (SELECT count() FROM system.clusters WHERE cluster = 'otel'),
             (SELECT uniqExact(tables) = 1 AND count() = ${hosts} FROM (
                SELECT hostName() AS host, groupArraySorted(1000)(name) AS tables
                FROM clusterAllReplicas('otel', system.tables)
                WHERE database = 'otel' GROUP BY host))
      FORMAT TSV" 2>/dev/null | tr '\t' ' ')
  done
  echo "clickhouse: ${hosts} replicas with identical schema"
}

# Template changes reach a CHI only through a new spec.taskID, by operator design.
roll_sizing_template() {
  local hash task deadline=$((SECONDS + 900))
  hash=$(kubectl get chit otel-sizing -n "$NAMESPACE" -o jsonpath='{.spec}' | sha12)
  [ "$(kubectl get chi otel -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.pg-unified-o11y/sizing-hash}')" = "$hash" ] && return
  task="sizing-${hash}"
  kubectl patch chi otel -n "$NAMESPACE" --type=merge -p "{\"metadata\":{\"annotations\":{\"pg-unified-o11y/sizing-hash\":\"${hash}\"}},\"spec\":{\"taskID\":\"${task}\"}}"
  until kubectl get chi otel -n "$NAMESPACE" -o jsonpath='{.status.taskIDsCompleted}' | grep -q "\"${task}\""; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "error: chi/otel did not complete ${task}" >&2; exit 1; }
    sleep 5
  done
  echo "chi/otel reconciled with otel-sizing ${hash}"
}

wait_completed chk otel
wait_completed chi otel
roll_sizing_template
kubectl wait --for=condition=Ready pod -l clickhouse.altinity.com/chi=otel -n "$NAMESPACE" --timeout=300s
kubectl wait --for=condition=Complete job/clickhouse-schema -n "$NAMESPACE" --timeout=600s
wait_replicas_converged

# The operator creates the workloads asynchronously.
wait_for_workload() {
  local deadline=$((SECONDS + 300))
  until kubectl get "$1" -n "$NAMESPACE" &>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "error: $1 not created" >&2; exit 1; }
    sleep 5
  done
  kubectl rollout status "$1" -n "$NAMESPACE" --timeout=300s
}

wait_for_workload statefulset/otel-gateway-collector
wait_for_workload daemonset/otel-agent-collector
wait_for_workload deployment/otel-scraper-targetallocator
wait_for_workload statefulset/otel-scraper-collector

for cluster in "${CLUSTERS[@]}"; do
  kubectl wait --for=condition=Ready "cluster/${PG_NAME}" -n "$cluster" --timeout=600s
done

kubectl rollout status deployment/grafana -n "$NAMESPACE" --timeout=300s
for cluster in "${CLUSTERS[@]}"; do
  kubectl rollout status deployment/hammerdb -n "$cluster" --timeout=600s
done
