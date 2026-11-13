#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
require_kind_context
source "${SCRIPT_DIR}/_chaos.sh"

for cluster in "${CLUSTERS[@]}"; do
  kubectl patch cluster "$PG_NAME" -n "$cluster" --type=merge \
    -p "{\"spec\":{\"postgresql\":{\"parameters\":${OVERRIDE}}}}" >/dev/null
  wait_planner "$cluster" off
  printf '=== %s: planner override applied\n%s\n' "$cluster" "$(show_planner "$cluster")"
done
