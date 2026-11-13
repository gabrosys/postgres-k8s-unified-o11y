#!/usr/bin/env bash
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

failed=()
for t in lint operators images clickhouse schema pipeline postgres timeline workload grafana dashboards health; do
  echo "=== ${t}"
  "${TEST_DIR}/${t}.sh" || failed+=("$t")
done

[ ${#failed[@]} -eq 0 ] || { echo "failed: ${failed[*]}" >&2; exit 1; }
