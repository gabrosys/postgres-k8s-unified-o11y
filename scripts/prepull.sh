#!/usr/bin/env bash
# Pulls every image a pod uses onto every kind worker, then reports anything still missing.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
mapfile -t imgs < <(kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' | sort -u | grep -v '^localhost/')
mapfile -t nodes < <(kind get nodes --name "$CLUSTER_NAME" | grep worker)
[ "${1:-}" = check ] || for n in "${nodes[@]}"; do for i in "${imgs[@]}"; do
  docker exec "$n" crictl pull "$i" >/dev/null 2>&1 || echo "$n: pull failed $i"
done; done
status=0
for n in "${nodes[@]}"; do
  have=$(docker exec "$n" crictl images --digests -o json | jq -r '.images[] | (.repoTags[]?, .repoDigests[]?)')
  for i in "${imgs[@]}"; do
    key="${i#*@}"; [ "$key" = "$i" ] && key="$i"
    grep -qF "$key" <<< "$have" || grep -qF "docker.io/$key" <<< "$have" || { echo "$n: missing $i"; status=1; }
  done
done
[ $status = 0 ] && echo "${#imgs[@]} images cached on ${#nodes[@]} workers"
exit $status
