#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${ROOT_DIR}/deploy/base/grafana/dashboards"

# Each dashboard uid and the variables a link into it must set.
declare -A REQUIRED=([pg-service]="service" [pg-fleet]="" [pg-query]="cluster query_id" [pg-trace]="trace_id" [o11y-pipeline]="")

status=0
bad() { echo "FAIL $1" >&2; status=1; }

for uid in "${!REQUIRED[@]}"; do
  [ -n "$(grep -l "\"uid\": *\"${uid}\"" "$DIR"/*.json 2>/dev/null)" ] || bad "no dashboard with uid ${uid}"
done

for f in "$DIR"/*.json; do
  name=$(basename "$f")
  uid=$(jq -r .uid "$f")
  [ -n "${REQUIRED[$uid]+x}" ] || bad "${name}: uid ${uid} is not in the dashboard set"

  hits=$(jq -r '[.. | strings] | .[]' "$f" | grep -ioE 'pg-alpha|pg-beta|tpcc|checkout|hammerdb' | sort -u | tr '\n' ' ')
  [ -z "$hits" ] || bad "${name}: hardcoded ${hits}"

  visible=$(jq '[.panels[] | select(.type != "row")] | (map(select(.type != "stat")) | length) + (if any(.type == "stat") then 1 else 0 end)' "$f")
  [ "$visible" -le 4 ] || bad "${name}: ${visible} visible panels, max 4"

  rows=$(jq -c '[.panels[] | select(.type == "row") | {title, collapsed}]' "$f")
  [ "$rows" = '[]' ] || [ "$rows" = '[{"title":"Details","collapsed":true}]' ] || bad "${name}: rows ${rows}, want none or one collapsed Details"

  while read -r url; do
    target=$(sed -nE 's|.*/d/([^/?]+).*|\1|p' <<< "$url")
    [ -n "${REQUIRED[$target]+x}" ] || { bad "${name}: link to unknown dashboard ${target}"; continue; }
    for v in ${REQUIRED[$target]}; do
      grep -q "var-${v}=" <<< "$url" || bad "${name}: link to ${target} misses var-${v}"
    done
  done < <(jq -r '[.. | strings | select(test("/d/"))] | .[]' "$f")

  if [ "$uid" = pg-service ]; then
    missing=$(jq '[.. | objects | select(has("targets")) | select((.fieldConfig.defaults.noValue // "") == "")] | length' "$f")
    [ "$missing" = 0 ] || bad "${name}: ${missing} panels without a noValue text"
  fi
done

[ "$status" = 0 ] && echo "dashboard rules: ok"
exit "$status"
