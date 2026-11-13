#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "Cluster '${CLUSTER_NAME}' already exists."
  exit 0
fi

kind create cluster --name "${CLUSTER_NAME}" --config "${ROOT_DIR}/hack/kind/cluster.yaml"
require_kind_context
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl get nodes
