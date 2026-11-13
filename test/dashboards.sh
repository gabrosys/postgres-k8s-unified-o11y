#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_kind_context

# Runs every panel query through Grafana with the dashboard variables filled in.
CLUSTER="${CLUSTERS[0]}"
INSTANCE=$(kubectl get cluster "$PG_NAME" -n "$CLUSTER" -o jsonpath='{.status.currentPrimary}')
QID=$(CH_FORMAT=TSV ch_query "SELECT any(LogAttributes['query_id']) FROM otel_logs
  WHERE ServiceName = 'pg_stat_ch' AND LogAttributes['db.query.text'] LIKE '%COUNT(DISTINCT (s_i_id))%'")
TID=$(CH_FORMAT=TSV ch_query "SELECT argMax(TraceId, Duration) FROM otel_traces
  WHERE ServiceName = 'PostgreSQL_Server' AND Timestamp > now() - INTERVAL 15 MINUTE")

expand() {
  sed -e "s/\${cluster:singlequote}/'${CLUSTER}'/g; s/\${instance:singlequote}/'${INSTANCE}'/g" \
      -e "s/\${cluster}/${CLUSTER}/g; s/\${instance}/${INSTANCE}/g; s/\${query_id}/${QID}/g; s/\${trace_id}/${TID}/g" \
      -e "s/\$cluster/${CLUSTER}/g; s/\$instance/${INSTANCE}/g; s/\$query_id/${QID}/g; s/\$trace_id/${TID}/g"
}

# Arguments name the dashboards to check; none checks all of them.
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
    err=$(curl -s --max-time 60 -u admin:admin http://localhost:3000/api/ds/query \
            -H 'Content-Type: application/json' -d "$body" | jq -r '.results.A.error // empty')
    [ -z "$err" ] && pass "${dash}: ${title}" || fail "${dash}: ${title}: $(tr '\n' ' ' <<< "$err" | cut -c1-120)"
  done < <(jq -c '.. | objects | select(has("targets")) | .title as $t | .targets[]
                  | select(.rawSql != null) | {title: $t, rawSql, format}' "$f")
done

exit "$FAILED"
