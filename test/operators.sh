#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_kind_context

for crd in \
  clusters.postgresql.cnpg.io \
  clickhouseinstallations.clickhouse.altinity.com \
  clickhousekeeperinstallations.clickhouse-keeper.altinity.com \
  opentelemetrycollectors.opentelemetry.io \
  podmonitors.monitoring.coreos.com \
  servicemonitors.monitoring.coreos.com; do
  kubectl get crd "$crd" &>/dev/null && pass "CRD ${crd}" || fail "CRD ${crd} missing"
done

for ns in cnpg-system clickhouse-operator opentelemetry-operator; do
  total=$(kubectl get deploy -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready=$(kubectl get deploy -n "$ns" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Available")].status}{"\n"}{end}' 2>/dev/null | grep -c True || true)
  [ "$total" -gt 0 ] && [ "$ready" -eq "$total" ] \
    && pass "${ns}: ${ready}/${total} deployments Available" \
    || fail "${ns}: ${ready}/${total} deployments Available"
done

for gone in namespace/cert-manager crd/objectstores.barmancloud.cnpg.io; do
  kubectl get "$gone" &>/dev/null && fail "${gone} still installed" || pass "${gone} not installed"
done

exit "$FAILED"
