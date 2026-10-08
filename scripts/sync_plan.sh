#!/usr/bin/env bash
# Preview `make sync`: the rule from the data scope file and the expected rows
# for every table, from prod's optimizer statistics. Reads prod only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
resolve_settings
require_vars APP_SCHEMA PROD_USER PROD_PASSWORD
require_prod_target
validate_identifier "$APP_SCHEMA" schema
schema="$(upper "$APP_SCHEMA")"
scope_file="$(data_scope_file)"
ensure_network
ensure_sqlcl_image

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
if scope_uses_used "$scope_file"; then
  prod_used_tables > "$work/used.txt" || die "could not read dependencies from prod" 2
  expand_used_scope "$scope_file" "$work/used.txt" > "$work/scope.conf"
  echo "USED: $(grep -c . "$work/used.txt" || true) table(s) used by packages"
  scope_file="$work/scope.conf"
fi
scope_to_plsql "$scope_file" "$schema" >/dev/null || die "fix the data scope file and retry"

tables="$(sqlcl_prod <<SQL | between_markers | tr -d ' '
set heading off feedback off pagesize 0 linesize 4000
prompt __BEGIN__
select table_name || '|' || num_rows from all_tables
 where owner = '$schema' and nested = 'NO' and secondary = 'N' order by table_name;
prompt __END__
SQL
)" || die "could not read from prod" 2

printf '%s\n' "$tables" | grep -v '^$' | scope_plan "$scope_file" | awk -F'\t' '
  BEGIN { printf "%-30s %-40s %14s %14s\n", "TABLE", "RULE", "ROWS ON PROD", "ROWS TO COPY" }
  $1 == "TOTAL" { printf "%-30s %-40s %14s %14s\n", "", "", "------------", "------------" }
  { printf "%-30s %-40s %14s %14s\n", $1, substr($2, 1, 40), $3, $4 }'
cat <<'EOF2'

Rows come from optimizer statistics ("?" = no statistics, or a WHERE rule).
Parent rows referenced by limited tables are copied on top of these numbers.
EOF2
