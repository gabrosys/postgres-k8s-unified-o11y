#!/bin/bash
set -euo pipefail

source /scripts/ch.sh

# A host skips ON CLUSTER DDL until it lists itself, and hosts join one at a time.
until [ "$(ch "SELECT count() = ${CH_HOSTS} * ${CH_HOSTS} AND countIf(is_local) = ${CH_HOSTS}
               FROM clusterAllReplicas('otel', system.clusters) WHERE cluster = 'otel'" 2>/dev/null)" = 1 ]; do
  echo "waiting for ${CH_HOSTS} hosts in cluster otel"
  sleep 5
done

ch "CREATE DATABASE IF NOT EXISTS otel ON CLUSTER otel"
