#!/usr/bin/env bash
# SQLcl on the local DB as APP_SCHEMA.
# usage: sql.sh               interactive (terminal)
#        sql.sh script.sql    run a file
#        sql.sh < script.sql  run stdin (what Claude Code uses)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
resolve_settings
require_vars APP_SCHEMA LOCAL_SYS_PASSWORD
ensure_network
ensure_sqlcl_image

if (($# > 0)); then
  [[ -f "$1" ]] || die "file not found: $1"
  { echo "set serveroutput on size unlimited"; cat "$1"; } | sqlcl_local "$APP_SCHEMA"
elif [[ -t 0 ]]; then
  exec docker run --rm -it --network "$DOCKER_NETWORK" -v "$REPO_ROOT":/work -w /work \
    "$SQLCL_IMAGE" sql "$APP_SCHEMA/\"$LOCAL_SYS_PASSWORD\"@$LOCAL_HOST:1521/$LOCAL_SERVICE"
else
  { echo "set serveroutput on size unlimited"; cat; } | sqlcl_local "$APP_SCHEMA"
fi
