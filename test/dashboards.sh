#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_kind_context

# Runs every panel query through Grafana with the dashboard variables filled in.
CLUSTER="${CLUSTERS[0]}"
INSTANCE=$(kubectl get cluster "$PG_NAME" -n "$CLUSTER" -o jsonpath='{.status.currentPrimary}')
# QID and TID may be set by the caller; by default the busiest statement and the slowest recent trace.
QID="${QID:-$(CH_FORMAT=TSV ch_query "SELECT LogAttributes['query_id'] AS q FROM otel_logs
  WHERE ServiceName = 'pg_stat_ch' AND Timestamp > now() - INTERVAL 15 MINUTE AND q NOT IN ('', '0')
  GROUP BY q ORDER BY count() DESC LIMIT 1")}"
TID="${TID:-$(CH_FORMAT=TSV ch_query "SELECT argMax(TraceId, Duration) FROM otel_traces
  WHERE ServiceName = 'PostgreSQL_Server' AND Timestamp > now() - INTERVAL 15 MINUTE")}"
SERVICE="${SERVICE-$(CH_FORMAT=TSV ch_query "SELECT any(ServiceName) FROM otel_traces
  WHERE SpanKind = 'Server' AND ServiceName != 'PostgreSQL_Server' AND Timestamp > now() - INTERVAL 15 MINUTE")}"

expand() {
  sed -e "s/\${cluster:singlequote}/'${CLUSTER}'/g; s/\${instance:singlequote}/'${INSTANCE}'/g" \
      -e "s/\${cluster}/${CLUSTER}/g; s/\${instance}/${INSTANCE}/g; s/\${query_id}/${QID}/g; s/\${trace_id}/${TID}/g; s/\${service}/${SERVICE}/g" \
      -e "s/\$cluster/${CLUSTER}/g; s/\$instance/${INSTANCE}/g; s/\$query_id/${QID}/g; s/\$trace_id/${TID}/g; s/\$service/${SERVICE}/g"
}

# Arguments name the dashboards to check; none checks all of them. Panels whose title
# matches NONEMPTY must return rows.
dir="${ROOT_DIR}/deploy/base/grafana/dashboards"
if [ $# -gt 0 ]; then files=("${@/#/${dir}/}"); files=("${files[@]/%/.json}"); else files=("$dir"/*.json); fi

for f in "${files[@]}"; do
  [ -f "$f" ] || { fail "no dashboard $(basename "$f")"; continue; }
  dash=$(basename "$f" .json)
  while read -r target; do
    title=$(jq -r .title <<< "$target")
    body=$(jq -c --arg sql "$(jq -r .rawSql <<< "$target" | expand)" \
      '{from: "now-30m", to: "now", queries: [{refId: "A", datasource: {uid: "clickhouse"},
        editorType: "sql", format: (.format // 1), rawSql: $sql}]}' <<< "$target")
    out=$(curl -s --max-time 60 -u admin:admin http://localhost:3000/api/ds/query \
            -H 'Content-Type: application/json' -d "$body")
    err=$(jq -r '.results.A.error // empty' <<< "$out")
    rows=$(jq '[.results.A.frames[]?.data.values[0] // [] | length] | add // 0' <<< "$out")
    if [ -n "$err" ]; then
      fail "${dash}: ${title}: $(tr '\n' ' ' <<< "$err" | cut -c1-120)"
    elif [ -n "${NONEMPTY:-}" ] && [[ "$title" =~ $NONEMPTY ]] && [ "$rows" = 0 ]; then
      fail "${dash}: ${title}: no rows"
    else
      pass "${dash}: ${title} (${rows} rows)"
    fi
  done < <(jq -c '.. | objects | select(has("targets")) | .title as $t | .targets[]
                  | select(.rawSql != null) | {title: $t, rawSql, format}' "$f")
done

exit "$FAILED"
