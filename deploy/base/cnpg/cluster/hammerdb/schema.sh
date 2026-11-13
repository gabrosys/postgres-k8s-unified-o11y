#!/bin/sh
set -eu

complete() { [ "$(psql -tAc "SELECT count(*) FROM pg_proc WHERE proname = 'slev'")" = 1 ]; }

until psql -qc 'SELECT 1' >/dev/null 2>&1; do
  echo "waiting for ${PGHOST}"
  sleep 5
done

# The build creates its functions last, so a complete schema has them all.
if complete; then
  echo "schema present, skipping build"
  exit 0
fi

psql -qc 'DROP OWNED BY CURRENT_USER'
./hammerdbcli auto /scripts/build.tcl

# hammerdbcli exits 0 even when the build fails.
complete || { echo "schema build failed" >&2; exit 1; }
