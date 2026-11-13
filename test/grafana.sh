#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_kind_context

GRAFANA="http://localhost:3000"
api() { curl -sf --max-time 20 -u admin:admin "${GRAFANA}$1" "${@:2}"; }

grep -q '"database": *"ok"' <<< "$(api /api/health || true)" && pass "Grafana healthy" || fail "Grafana unhealthy"
grep -q '"status": *"OK"' <<< "$(api /api/datasources/uid/clickhouse/health || true)" \
  && pass "datasource reaches ClickHouse" || fail "datasource health failed"
grep -q '"username": *"grafana"' <<< "$(api /api/datasources/uid/clickhouse || true)" \
  && pass "datasource uses the read-only grafana user" || fail "datasource user is not grafana"

for uid in pg-unified-o11y pg-query-detail pipeline-health; do
  api "/api/dashboards/uid/${uid}" >/dev/null && pass "dashboard ${uid} provisioned" || fail "dashboard ${uid} missing"
done

body='{"from":"now-15m","to":"now","queries":[{"refId":"A","datasource":{"uid":"clickhouse"},
       "editorType":"sql","format":1,"rawSql":"SELECT count() FROM otel.otel_traces"}]}'
out=$(api /api/ds/query -H 'Content-Type: application/json' -d "$body" || true)
grep -q '"status": *200' <<< "$out" && ! grep -q '"error"' <<< "$out" \
  && pass "query through Grafana returns data" || fail "query through Grafana failed: ${out:0:200}"

exit "$FAILED"
