#!/usr/bin/env bash

CLUSTER_NAME="${CLUSTER_NAME:-pg-unified-o11y}"
CONTEXT="${CONTEXT:-kind-${CLUSTER_NAME}}"
NAMESPACE="${NAMESPACE:-o11y}"

PG_IMAGE="${PG_IMAGE:-pg-o11y:18}"
PGLOAD_IMAGE="${PGLOAD_IMAGE:-pgload:1}"
OTEL_COLLECTOR_IMAGE="${OTEL_COLLECTOR_IMAGE:-ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.159.0}"

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

# First 12 hex characters of the SHA-256 of stdin.
sha12() {
  if command -v sha256sum &>/dev/null; then sha256sum; else shasum -a 256; fi | cut -c1-12
}

ensure_namespace() {
  kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f -
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
