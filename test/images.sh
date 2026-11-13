#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
BASE="$(image postgres)"

# check_extension KEY NAME: the image's libraries resolve inside the operand image.
check_extension() {
  local ref dir out cid
  ref="$(image "$1")"
  [ "$(docker image inspect -f '{{index .Config.Labels "io.cnpg.base"}}' "$ref" 2>/dev/null)" = "$BASE" ] \
    && pass "$2: built from the pinned operand image" || fail "$2: base label differs from images.txt postgres"

  dir="${WORK}/$2"
  mkdir -p "$dir"
  cid=$(docker create "$ref" x)
  docker export "$cid" | tar -xf - -C "$dir" lib share system 2>/dev/null || true
  docker rm "$cid" >/dev/null
  [ -f "${dir}/share/extension/$2.control" ] && pass "$2: control file present" || fail "$2: control file missing"

  out=$(docker run --rm -v "${dir}:/extensions/$2:ro" -e "LD_LIBRARY_PATH=/extensions/$2/system" \
          --entrypoint sh "$BASE" -c "ldd /extensions/$2/lib/$2.so" 2>&1 || true)
  ! grep -q 'not found' <<< "$out" && grep -q '=>' <<< "$out" \
    && pass "$2: shared libraries resolve" || fail "$2: unresolved libraries: $(grep 'not found' <<< "$out" | tr -s ' \t' ' ')"
}

check_extension pg-tracing-ext pg_tracing
check_extension pg-stat-ch-ext pg_stat_ch

exit "$FAILED"
