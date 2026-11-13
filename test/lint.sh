#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRDS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

shopt -s nullglob
overlays=("${ROOT_DIR}"/deploy/overlays/*/)
[ ${#overlays[@]} -gt 0 ] || { echo "no overlays under deploy/overlays" >&2; exit 1; }

status=0
for overlay in "${overlays[@]}"; do
  echo "== ${overlay#"${ROOT_DIR}/"}"
  rendered=$(kubectl kustomize "$overlay")
  kubeconform -strict -summary -schema-location default -schema-location "$CRDS" <<< "$rendered"

  while read -r ref; do
    grep -qxF "$ref" <(cut -d= -f2- "${ROOT_DIR}/images.txt") \
      || { echo "image not pinned in images.txt: ${ref}" >&2; status=1; }
  done < <(sed -nE 's/^[[:space:]-]*(image|reference):[[:space:]]*"?([^"[:space:]]+)"?.*/\2/p' <<< "$rendered" | sort -u)

  # The schema Job waits for CH_HOSTS hosts; it must match the CHI topology.
  hosts=$(yq 'select(.kind == "ClickHouseInstallation") | .spec.configuration.clusters[] | select(.name == "otel")
              | .layout.shardsCount * .layout.replicasCount' <<< "$rendered")
  job=$(yq 'select(.kind == "Job" and .metadata.name == "clickhouse-schema")
            | .spec.template.spec.initContainers[] | select(.name == "database") | .env[] | select(.name == "CH_HOSTS") | .value' <<< "$rendered")
  [ "$hosts" = "$job" ] || { echo "schema Job expects ${job} hosts, CHI defines ${hosts}" >&2; status=1; }
done
exit "$status"
