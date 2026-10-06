#!/usr/bin/env bash

PG_CLUSTER="${PG_CLUSTER:-pg-alpha}"
DATABASE="${DATABASE:-demo}"

read -r -a CLUSTERS <<< "${PG_CLUSTERS:-pg-alpha pg-beta}"

pg_psql() {
  local pod
  pod=$(kubectl get pod -n "$PG_CLUSTER" \
    -l "cnpg.io/cluster=${PG_CLUSTER},cnpg.io/instanceRole=primary" \
    -o jsonpath='{.items[0].metadata.name}')
  if [ -z "$pod" ]; then
    echo "error: no primary pod for cluster '${PG_CLUSTER}'" >&2
    return 1
  fi
  kubectl exec -n "$PG_CLUSTER" -i "$pod" -c postgres -- \
    psql -U postgres -d "$DATABASE" -v ON_ERROR_STOP=1 "$@"
}
