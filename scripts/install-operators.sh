#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
require_kind_context
source "${ROOT_DIR}/deploy/charts/versions.env"

CHARTS_DIR="${ROOT_DIR}/deploy/charts"

helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update >/dev/null
helm repo add altinity https://helm.altinity.com --force-update >/dev/null
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null

# install RELEASE CHART VERSION NAMESPACE [helm args...]
install() {
  local release="$1" chart="$2" version="$3" ns="$4"
  shift 4
  echo "=== ${release} ${version}"
  helm upgrade --install "$release" "$chart" --version "$version" \
    --namespace "$ns" --create-namespace --wait --timeout 5m "$@"
}

collector="$(image otel-collector)"

install prometheus-operator-crds prometheus-community/prometheus-operator-crds \
  "$PROMETHEUS_CRDS_CHART_VERSION" prometheus-crds
install cnpg cnpg/cloudnative-pg "$CNPG_CHART_VERSION" cnpg-system
install clickhouse-operator altinity/altinity-clickhouse-operator \
  "$ALTINITY_CHART_VERSION" clickhouse-operator --values "${CHARTS_DIR}/altinity/values.yaml"
install opentelemetry-operator open-telemetry/opentelemetry-operator \
  "$OTEL_OPERATOR_CHART_VERSION" opentelemetry-operator --values "${CHARTS_DIR}/otel-operator/values.yaml" \
  --set "manager.collectorImage.repository=${collector%:*}" \
  --set "manager.collectorImage.tag=${collector##*:}"
