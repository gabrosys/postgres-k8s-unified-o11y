#!/bin/sh
set -eu

# Each version file declares the state of that release, so a restart re-applies it as a no-op.
version="${APP_VERSION:-1}"
psql -v ON_ERROR_STOP=1 -f /migrations/schema.sql
psql -v ON_ERROR_STOP=1 -f "/migrations/${version}.sql"
