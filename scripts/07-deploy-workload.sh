#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/_env.sh"
require_kind_context
source "${SCRIPT_DIR}/_pg-env.sh"

docker build -t "${PGLOAD_IMAGE}" "${ROOT_DIR}/docker/pgload"
kind load docker-image "${PGLOAD_IMAGE}" --name "${CLUSTER_NAME}"

# The tag is stable, so a source hash annotation rolls the pods on change.
SOURCE_HASH=$(cat "${ROOT_DIR}"/docker/pgload/{main.go,go.mod,go.sum,Dockerfile} | sha12)

for cluster in "${CLUSTERS[@]}"; do
  render "${ROOT_DIR}/manifests/pgload/pgload.yaml" \
      "CLUSTER=${cluster}" "SOURCE_HASH=${SOURCE_HASH}" "PGLOAD_IMAGE=${PGLOAD_IMAGE}" \
    | kubectl apply -n "$cluster" -f -
done

for cluster in "${CLUSTERS[@]}"; do
  kubectl rollout status deployment/pgload -n "$cluster" --timeout=180s
done
