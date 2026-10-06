#!/usr/bin/env bash

EXPLAIN_LOOKUP="EXPLAIN (VERBOSE, COSTS OFF)
  SELECT id, kind, amount FROM pgload_events WHERE ext_id = 'ext-12345'"

# Runs SQL on every cluster, then prints the lookup plan and its query identifier.
chaos_apply() {
  local label="$1" sql="$2" cluster

  for cluster in "${CLUSTERS[@]}"; do
    printf '=== %s: %s ===\n' "$cluster" "$label"
    PG_CLUSTER="$cluster" pg_psql -q -c "$sql"
    PG_CLUSTER="$cluster" pg_psql -tAc "$EXPLAIN_LOOKUP" \
      | grep -Ei 'scan|query identifier'
  done
}
