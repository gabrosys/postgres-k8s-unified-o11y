#!/usr/bin/env bash
# Cross-signal queries against ClickHouse: correlate.sh top | timeline | drill
#   PG_CLUSTERS cluster to inspect, one name (same variable as chaos-degrade; default pg-alpha)
#   PG_CLUSTER  alias of PG_CLUSTERS for a single cluster, wins when both are set
#   WINDOW_MIN  look-back window in minutes   (default 10)
#   QUERY_ID    required by timeline; drill uses it to pick the slowest trace
#   TRACE_ID    drill target
set -euo pipefail

EXPLICIT_CLUSTER="${PG_CLUSTER:-}"
die() { echo "error: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_env.sh"
require_kind_context
source "${SCRIPT_DIR}/_pg-env.sh"
source "${SCRIPT_DIR}/_ch-env.sh"

# One cluster per run: PG_CLUSTER wins, else the single name in PG_CLUSTERS
# (the variable chaos-degrade reads), else the default.
if [ -z "$EXPLICIT_CLUSTER" ] && [ -n "${PG_CLUSTERS:-}" ]; then
  [ "${#CLUSTERS[@]}" -eq 1 ] || die "PG_CLUSTERS must name one cluster here (got '${PG_CLUSTERS}')"
  PG_CLUSTER="${CLUSTERS[0]}"
fi
QUERIES_DIR="${SCRIPT_DIR}/queries"
WINDOW_MIN="${WINDOW_MIN:-10}"
QUERY_ID="${QUERY_ID:-}"
TRACE_ID="${TRACE_ID:-}"

need() { [[ "$2" =~ $3 ]] || die "$1 must match $3 (got '$2')"; }

# Values are spliced into SQL, so each one is validated first.
need PG_CLUSTER "$PG_CLUSTER" '^[a-z0-9-]+$'
need WINDOW_MIN "$WINDOW_MIN" '^[0-9]+$'

echo "cluster: ${PG_CLUSTER}" >&2

run() {
  local file="$1"; shift
  CH_FORMAT="${CH_FORMAT:-PrettyCompactMonoBlock}" ch_query \
    "$(render "${QUERIES_DIR}/${file}" "NS=${PG_CLUSTER}" "MIN=${WINDOW_MIN}" "$@")"
}

require_query_id() {
  [ -n "$QUERY_ID" ] || die "QUERY_ID is required (see: make top-queries)"
  need QUERY_ID "$QUERY_ID" '^-?[0-9]+$'
}

case "${1:-}" in
  top)
    CH_FORMAT=Pretty run top.sql ;;
  timeline)
    require_query_id
    run timeline.sql "QID=${QUERY_ID}" ;;
  drill)
    if [ -z "$TRACE_ID" ]; then
      require_query_id
      TRACE_ID=$(CH_FORMAT=TSV ch_query \
        "$(render "${QUERIES_DIR}/slowest-trace.sql" "NS=${PG_CLUSTER}" "MIN=${WINDOW_MIN}" "QID=${QUERY_ID}")" \
        | tr -d '[:space:]')
      [ -n "$TRACE_ID" ] || die "no trace found for QUERY_ID=${QUERY_ID} in the last ${WINDOW_MIN} min"
      echo "slowest trace for ${QUERY_ID}: ${TRACE_ID}"
    fi
    need TRACE_ID "$TRACE_ID" '^[0-9a-f]{32}$'
    run drill.sql "TRACE=${TRACE_ID}" ;;
  *)
    die "usage: correlate.sh top|timeline|drill" ;;
esac
