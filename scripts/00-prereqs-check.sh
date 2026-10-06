#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_env.sh"

MIN_KIND_VERSION="0.30.0"
MISSING=()

for cmd in docker kind kubectl helm curl; do
  if command -v "$cmd" &>/dev/null; then
    printf "${GREEN}[OK]${NC}   %s (%s)\n" "$cmd" "$(command -v "$cmd")"
  else
    printf "${RED}[FAIL]${NC} %s not found\n" "$cmd"
    MISSING+=("$cmd")
  fi
done

if ! command -v sha256sum &>/dev/null && ! command -v shasum &>/dev/null; then
  printf "${RED}[FAIL]${NC} sha256sum or shasum not found\n"
  MISSING+=("sha256sum|shasum")
fi

if command -v kind &>/dev/null; then
  kind_version="$(kind version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ "$(printf '%s\n%s\n' "$MIN_KIND_VERSION" "$kind_version" | sort -V | head -1)" != "$MIN_KIND_VERSION" ]; then
    printf "${RED}[FAIL]${NC} kind %s < %s\n" "$kind_version" "$MIN_KIND_VERSION"
    MISSING+=("kind>=${MIN_KIND_VERSION}")
  fi
fi

if [ ${#MISSING[@]} -gt 0 ]; then
  printf "\n${RED}Missing: %s${NC}\n" "${MISSING[*]}"
  exit 1
fi
printf "\n${GREEN}All prerequisites installed.${NC}\n"
