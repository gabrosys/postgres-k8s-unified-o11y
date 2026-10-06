#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for step in 00-prereqs-check 01-kind-create 02-install-cnpg 03-build-load-image \
            04-install-clickhouse 05-install-otel 06-deploy-pg-cluster \
            07-deploy-workload 08-install-grafana; do
  echo ""
  echo "=== ${step} ==="
  "${SCRIPT_DIR}/${step}.sh"
done

echo ""
echo "Setup complete. Validate with: make smoke"
