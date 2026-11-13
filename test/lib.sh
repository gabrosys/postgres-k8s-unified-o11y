#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/env.sh"

FAILED=0
pass() { printf "${GREEN}[PASS]${NC} %s\n" "$1"; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$1"; FAILED=1; }
count() { ch_query "$1" 2>/dev/null | tr -d '[:space:]' || echo 0; }
check() { [ "${1:-0}" -gt 0 ] && pass "$2" || fail "$2"; }

# check_rows LABEL SQL: passes when SQL returns a positive count; %n in LABEL is the count.
check_rows() {
  local n
  n=$(count "$2")
  check "$n" "${1//%n/$n}"
}

# wait_for TIMEOUT_S CMD...: retries CMD every 5s until it succeeds or the timeout expires.
wait_for() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@" &>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 5
  done
}

# load_resumed NAMESPACE: HammerDB completed New-Order transactions in the last minute.
load_resumed() {
  [ "$(count "SELECT count() FROM otel_logs WHERE ServiceName = 'pg_stat_ch'
                AND ResourceAttributes['k8s.namespace.name'] = '$1'
                AND LogAttributes['db.query.text'] LIKE 'prepare neword%'
                AND Timestamp > now() - INTERVAL 1 MINUTE")" -gt 0 ]
}

# Retention value KEY as deployed by the overlay.
retention() {
  kubectl get configmap -n "$NAMESPACE" -l app.kubernetes.io/name=clickhouse-retention \
    -o jsonpath="{.items[0].data.$1}"
}
