#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
require_kind_context

base="$(image postgres)"

build() {
  docker build --build-arg "BASE=${base}" -t "$(image "$1")" "${ROOT_DIR}/images/$2"
  kind load docker-image "$(image "$1")" --name "$CLUSTER_NAME"
}

build pg-tracing-ext pg_tracing
build pg-stat-ch-ext pg_stat_ch
