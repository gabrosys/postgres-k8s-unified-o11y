#!/usr/bin/env bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Prints the pinned reference for KEY from images.txt.
image() {
  local ref
  ref=$(awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2) }' "${ROOT_DIR}/images.txt")
  [ -n "$ref" ] || { echo "error: no image '$1' in images.txt" >&2; return 1; }
  echo "$ref"
}

CLUSTER_NAME="${CLUSTER_NAME:-pg-unified-o11y}"
CONTEXT="${CONTEXT:-kind-${CLUSTER_NAME}}"
NAMESPACE="${NAMESPACE:-o11y}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

kubectl() { command kubectl --context "$CONTEXT" "$@"; }
helm()    { command helm --kube-context "$CONTEXT" "$@"; }

# A KIND apiserver is on loopback; anything else is not this cluster.
require_kind_context() {
  local server
  server=$(command kubectl config view --minify --context "$CONTEXT" \
             -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null) || true

  case "$server" in
    "")
      echo "error: kubectl context '${CONTEXT}' does not exist" >&2
      exit 1 ;;
    https://127.0.0.1:*|https://localhost:*|https://0.0.0.0:*|https://[::1]:*)
      ;;
    *)
      echo "error: context '${CONTEXT}' points at ${server}, not a local KIND cluster" >&2
      exit 1 ;;
  esac

  if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    echo "error: no KIND cluster named '${CLUSTER_NAME}'" >&2
    exit 1
  fi
}

sha12() {
  if command -v sha256sum &>/dev/null; then sha256sum; else shasum -a 256; fi | cut -c1-12
}

# Substitutes __KEY__ placeholders: render FILE KEY=VALUE...
render() {
  local file="$1" args=() pair
  shift
  for pair in "$@"; do
    args+=(-e "s|__${pair%%=*}__|${pair#*=}|g")
  done
  sed "${args[@]}" "$file"
}

# Every namespace runs one Cluster with this name; the namespace is its identity.
PG_NAME=pg
PG_CLUSTER="${PG_CLUSTER:-pg-alpha}"
DATABASE="${DATABASE:-tpcc}"

read -r -a CLUSTERS <<< "${PG_CLUSTERS:-pg-alpha pg-beta}"

pg_psql() {
  local pod
  pod=$(kubectl get pod -n "$PG_CLUSTER" \
    -l "cnpg.io/cluster=${PG_NAME},cnpg.io/instanceRole=primary" \
    -o jsonpath='{.items[0].metadata.name}')
  if [ -z "$pod" ]; then
    echo "error: no primary pod for cluster '${PG_CLUSTER}'" >&2
    return 1
  fi
  kubectl exec -n "$PG_CLUSTER" -i "$pod" -c postgres -- \
    psql -U postgres -d "$DATABASE" -v ON_ERROR_STOP=1 "$@"
}

CH_DATABASE="${CH_DATABASE:-otel}"

ch_pod() {
  kubectl get pods -n "$NAMESPACE" -l clickhouse.altinity.com/chi=otel \
    -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}' | cut -d' ' -f1
}

ch_secret() {
  kubectl get secret -n "$NAMESPACE" clickhouse-credentials -o jsonpath="{.data.$1}" | base64 -d
}

# CH_USER and CH_PASSWORD select a user other than the pod-local default.
ch_query() {
  kubectl exec -n "$NAMESPACE" "$(ch_pod)" -c clickhouse -- \
    clickhouse-client --database "$CH_DATABASE" ${CH_FORMAT:+--format "$CH_FORMAT"} \
      ${CH_USER:+--user "$CH_USER"} ${CH_PASSWORD:+--password "$CH_PASSWORD"} --query "$1"
}
