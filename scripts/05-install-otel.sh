#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/_env.sh"
require_kind_context

# Config is read at startup; the hash annotation rolls the pods on change.
apply_with_hash() {
  render "$1" "CONFIG_HASH=$(sha12 < "$1")" "OTEL_COLLECTOR_IMAGE=${OTEL_COLLECTOR_IMAGE}" \
    | kubectl apply -f -
}

ensure_namespace "${NAMESPACE}"
kubectl apply -f "${ROOT_DIR}/manifests/otel/rbac.yaml"
apply_with_hash "${ROOT_DIR}/manifests/otel/collector.yaml"
apply_with_hash "${ROOT_DIR}/manifests/otel/agent.yaml"

kubectl rollout status deployment/otel-collector -n "${NAMESPACE}" --timeout=180s
kubectl rollout status daemonset/otel-agent -n "${NAMESPACE}" --timeout=180s
