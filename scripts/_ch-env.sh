#!/usr/bin/env bash

CH_DATABASE="${CH_DATABASE:-otel}"

ch_query() {
  kubectl exec -n "$NAMESPACE" statefulset/clickhouse -- \
    clickhouse-client --database "$CH_DATABASE" ${CH_FORMAT:+--format "$CH_FORMAT"} --query "$1"
}
