#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/_env.sh"
require_kind_context

ensure_namespace "${NAMESPACE}"
kubectl apply -f "${ROOT_DIR}/manifests/clickhouse/clickhouse.yaml"
kubectl rollout status statefulset/clickhouse -n "${NAMESPACE}" --timeout=300s

echo "ClickHouse HTTP: http://localhost:8123"
