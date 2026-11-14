#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
require_kind_context
source "${SCRIPT_DIR}/_chaos.sh"

for cluster in "${CLUSTERS[@]}"; do
  for p in enable_indexscan enable_bitmapscan; do
    kubectl patch cluster "$PG_NAME" -n "$cluster" --type=json \
      -p "[{\"op\":\"remove\",\"path\":\"/spec/postgresql/parameters/${p}\"}]" >/dev/null 2>&1 || true
  done
  wait_planner "$cluster" on
  printf '=== %s: planner override removed\n%s\n' "$cluster" "$(show_planner "$cluster")"
done
