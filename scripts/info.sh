#!/usr/bin/env bash
# Print how to connect a SQL client (DBeaver, PL/SQL Developer, ...) to the local DB.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
resolve_settings
require_vars APP_SCHEMA LOCAL_SYS_PASSWORD
validate_identifier "$APP_SCHEMA" schema

state="$(docker inspect -f '{{.State.Status}}' "$LOCAL_HOST" 2>/dev/null || echo "not created")"
local_conn_info
echo
case "$state" in
  running) echo "Status: running" ;;
  *) echo "Status: $state - start it with: make up" ;;
esac
if [[ "$state" == running ]] && ! sqlcl_local "$APP_SCHEMA" </dev/null >/dev/null 2>&1; then
  echo "Note: user $(upper "$APP_SCHEMA") does not exist yet - run: make sync"
fi
