#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_env.sh"
require_kind_context

CNPG_CHART_VERSION="0.29.0"

helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update cnpg

helm upgrade --install cnpg-operator cnpg/cloudnative-pg \
  --version "${CNPG_CHART_VERSION}" \
  --namespace cnpg-system \
  --create-namespace \
  --wait

kubectl wait --for=condition=Available deployment/cnpg-operator-cloudnative-pg \
  --namespace cnpg-system --timeout=180s
kubectl get pods -n cnpg-system
