#!/usr/bin/env bash
# Recreate APP_SCHEMA in the local DB from ci/schema/*.sql (structure only).
# Used by the PR check; also handy for a clean local schema without prod access.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
resolve_settings
require_vars APP_SCHEMA LOCAL_SYS_PASSWORD
ensure_network
ensure_sqlcl_image
cd "$REPO_ROOT"

recreate_local_schema "$APP_SCHEMA"
files=()
for f in ci/schema/*.sql; do
  if [[ -f "$f" ]]; then files+=("$f"); fi
done
if ((${#files[@]} == 0)); then
  echo "ci/schema/ is empty: schema $APP_SCHEMA created without objects"
  exit 0
fi

out="$({
  for f in "${files[@]}"; do echo "@$f"; done
} | sqlcl_local system)" || die "cannot connect to the local DB (run: make up)" 2
errors="$(printf '%s\n' "$out" | grep -E '^(ORA|SP2|PLS)-[0-9]+' || true)"
if [[ -n "$errors" ]]; then
  echo "warning: some ci/schema statements failed:" >&2
  printf '%s\n' "$errors" >&2
fi
echo "applied ${#files[@]} file(s) from ci/schema/ into $APP_SCHEMA"
