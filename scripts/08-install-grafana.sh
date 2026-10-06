#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/_env.sh"
require_kind_context

GRAFANA_DIR="${ROOT_DIR}/manifests/grafana"

kubectl create configmap grafana-datasource \
  --from-file="${GRAFANA_DIR}/datasource.yaml" \
  -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap grafana-dashboards \
  --from-file="${GRAFANA_DIR}/dashboards" \
  -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Provisioning is read at startup; the hash annotation rolls the pod on change.
HASH=$(cat "${GRAFANA_DIR}/grafana.yaml" "${GRAFANA_DIR}/datasource.yaml" \
           "${GRAFANA_DIR}/dashboards"/*.json | sha12)
render "${GRAFANA_DIR}/grafana.yaml" "CONFIG_HASH=${HASH}" | kubectl apply -f -

kubectl rollout status deployment/grafana -n "${NAMESPACE}" --timeout=300s

echo "Grafana: http://localhost:3000"
