#!/usr/bin/env bash

# The regression is a planner override left in the Cluster spec. CNPG reloads it:
# plans change, query ids do not.
OVERRIDE='{"enable_indexscan":"off","enable_bitmapscan":"off"}'

show_planner() {
  PG_CLUSTER="$1" pg_psql -tAc "SELECT name || ' = ' || setting FROM pg_settings
    WHERE name IN ('enable_indexscan', 'enable_bitmapscan') ORDER BY name"
}

# Waits until every instance of the cluster reports enable_indexscan = $2.
wait_planner() {
  local deadline=$((SECONDS + 120))
  until [ "$(PG_CLUSTER="$1" pg_psql -tAc "SHOW enable_indexscan")" = "$2" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "error: $1 did not reload" >&2; return 1; }
    sleep 3
  done
}
