#!/usr/bin/env bash

# A bind parameter, as the workload sends it. A literal in place of $1 yields a
# different query id than the one the pipeline records.
EXPLAIN_LOOKUP="SET plan_cache_mode = force_generic_plan;
PREPARE lookup(text) AS
  SELECT id, kind, amount FROM pgload_events WHERE ext_id = \$1;
EXPLAIN (VERBOSE, COSTS OFF) EXECUTE lookup('ext-12345')"

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
