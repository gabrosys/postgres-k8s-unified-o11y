#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_env.sh"
require_kind_context
source "${SCRIPT_DIR}/_pg-env.sh"
source "${SCRIPT_DIR}/_chaos.sh"

chaos_apply "index restored" "CREATE INDEX IF NOT EXISTS pgload_events_ext_id_idx
  ON pgload_events (ext_id); ANALYZE pgload_events"
