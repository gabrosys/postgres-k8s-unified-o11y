#!/bin/sh

db="clickhouse://clickhouse-otel:9000?username=migrate&password=${CH_PASSWORD}&database=otel&x-multi-statement=true&x-cluster-name=otel&x-migrations-table-engine=ReplicatedMergeTree"
m() { migrate -path=/migrations -database="$db" "$@"; }

m up && exit 0

# A failed ON CLUSTER statement leaves the version dirty. Every migration is
# idempotent, so step back one version and let the Job's retry apply it again.
v=$(m version 2>&1)
case "$v" in
  *dirty*) n=${v%% *}; m force -- $((n - 1 > 0 ? n - 1 : -1)) ;;
esac
exit 1
