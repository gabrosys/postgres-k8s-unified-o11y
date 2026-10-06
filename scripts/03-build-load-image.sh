#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/_env.sh"
require_kind_context

docker build \
  -t "${PG_IMAGE}" \
  -f "${ROOT_DIR}/docker/postgres/Dockerfile" \
  "${ROOT_DIR}/docker/postgres"

docker run --rm --entrypoint /bin/sh "${PG_IMAGE}" -c '
  set -e
  for ext in pg_tracing pg_stat_ch; do
    so="$(pg_config --pkglibdir)/${ext}.so"
    ldd "$so" | grep "not found" && { echo "unresolved deps in $so"; exit 1; }
  done
  echo "pg_tracing.so and pg_stat_ch.so link cleanly."
'

kind load docker-image "${PG_IMAGE}" --name "${CLUSTER_NAME}"
