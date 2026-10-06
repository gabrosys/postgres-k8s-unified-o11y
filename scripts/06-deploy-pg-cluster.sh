#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/_env.sh"
require_kind_context
source "${SCRIPT_DIR}/_pg-env.sh"

render "${ROOT_DIR}/manifests/cnpg/image-catalog.yaml" "PG_IMAGE=${PG_IMAGE}" | kubectl apply -f -

for cluster in "${CLUSTERS[@]}"; do
  ensure_namespace "$cluster"
  render "${ROOT_DIR}/manifests/cnpg/pg-cluster.yaml" "CLUSTER=${cluster}" \
    | kubectl apply -n "$cluster" -f -
done

for cluster in "${CLUSTERS[@]}"; do
  kubectl wait --for=condition=Ready "cluster/${cluster}" -n "$cluster" --timeout=600s

  # Silence tracing and statement logging for the operator's own roles.
  PG_CLUSTER="$cluster" pg_psql -q -o /dev/null -c "
    ALTER ROLE cnpg_metrics_exporter SET pg_tracing.sample_rate = 0;
    ALTER ROLE cnpg_metrics_exporter SET log_min_duration_statement = -1;
    ALTER ROLE postgres SET pg_tracing.sample_rate = 0;"
done

kubectl get clusters -A
