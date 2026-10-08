#!/usr/bin/env bash
# Look at one table on prod (read only): row count and the first rows, and the
# row count in the local DB when it has the table. Handy to confirm you are on
# the right database before a full sync.
# usage: peek.sh <table> [where-condition] [rows]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
resolve_settings
require_vars APP_SCHEMA PROD_USER PROD_PASSWORD
require_prod_target
[[ -n "${1:-}" ]] || die "usage: make peek TABLE=<table> [WHERE=\"<condition>\"] [ROWS=10]"
validate_identifier "$1" table
validate_identifier "$APP_SCHEMA" schema
table="$(upper "$1")"
where="${2:-}"
rows="${3:-10}"
schema="$(upper "$APP_SCHEMA")"
if [[ ! "$rows" =~ ^[0-9]+$ ]] || ((rows < 1 || rows > 1000)); then
  die "ROWS must be a number from 1 to 1000"
fi
# The condition goes into a query on prod: one line, no statement separator.
case "$where" in
  *\;* | *$'\n'* | *$'\r'*) die "WHERE must be a single condition (no ';' and no line breaks)" ;;
esac
if [[ -n "$where" ]]; then where_sql="where $where"; else where_sql=""; fi
ensure_network
ensure_sqlcl_image

echo "== prod: $schema.$table ${where:+(where $where)}"
out="$(sqlcl_prod <<SQL
set sqlformat default
set pagesize 1000 linesize 32767 trimout on feedback off
set transaction read only;
select count(*) as rows_on_prod from "$schema"."$table" $where_sql;
select * from (select * from "$schema"."$table" $where_sql) where rownum <= $rows;
rollback;
SQL
)" || die "could not read from prod (run: make check)" 2
printf '%s\n' "$out" | grep -v -e '^[[:space:]]*$' -e '^SQL Format Cleared' || true

state="$(docker inspect -f '{{.State.Status}}' "$LOCAL_HOST" 2>/dev/null || true)"
if [[ "$state" == running ]] && [[ -n "${LOCAL_SYS_PASSWORD:-}" ]]; then
  local_count="$(sqlcl_local system 2>/dev/null <<SQL | between_markers | tr -d '[:space:]'
set heading off feedback off pagesize 0
prompt __BEGIN__
select count(*) from "$schema"."$table" $where_sql;
prompt __END__
SQL
)" || true
  echo
  if [[ "$local_count" =~ ^[0-9]+$ ]]; then
    echo "== local DB: $local_count rows ${where:+(same condition)}"
  else
    echo "== local DB: table not there yet (make sync)"
  fi
fi
