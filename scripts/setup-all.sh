#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for step in prereqs kind-create install-operators build-images deploy; do
  echo ""
  echo "=== ${step} ==="
  "${SCRIPT_DIR}/${step}.sh"
done

echo ""
echo "Setup complete. Validate with: make smoke"
