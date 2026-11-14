#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
require_kind_context

# Rolls out checkout at APP_VERSION $1. The init container applies migrations up to it:
# 2 drops checkout_ol_item, 3 recreates it.
version="${1:?usage: incident.sh VERSION}"
kubectl set env deployment/checkout -n pg-alpha "APP_VERSION=${version}"
kubectl rollout status deployment/checkout -n pg-alpha --timeout=600s
