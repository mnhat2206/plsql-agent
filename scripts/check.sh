#!/usr/bin/env bash
# Check .env and every connection that `make sync` and `make deploy` need, and
# say what to fix. Reads only; changes nothing (a temporary database link in the
# local DB is created and dropped to test the path local DB -> prod).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

failed=0
ok() { echo "  ✔ $1"; }
bad() { echo "  ✘ $1"; failed=1; }
warn() { echo "  ! $1"; }
hint() { echo "    → $1"; }
finish() {
  echo
  if ((failed)); then
    echo "Fix the items marked ✘ (usually in .env) and run make check again."
    exit 1
  fi
  echo "All good. Next: make up && make sync"
  exit 0
}
valid_name() { [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_\$#]*$ ]]; }

echo "Settings"
if [[ -f "$REPO_ROOT/.env" ]]; then ok ".env found"; else bad "no .env file"; hint "cp .env.example .env, then fill in your prod"; fi
load_env

missing=""
for v in PROD_USER PROD_PASSWORD APP_SCHEMA LOCAL_SYS_PASSWORD; do
  if [[ -z "${!v:-}" ]]; then missing="$missing $v"; fi
done
if [[ -z "${PROD_CONNECT:-}" && -z "${PROD_TNS:-}" ]]; then missing="$missing PROD_CONNECT"; fi
if [[ -n "$missing" ]]; then bad "missing in .env:$missing"; finish; fi

settings_ok=1
if [[ "${PROD_PASSWORD}" == change_me || "${PROD_CONNECT:-}" == *db.example.com* ]]; then
  bad ".env still has the example values"; hint "put your prod host, user and password in .env"; settings_ok=0
fi
for v in APP_SCHEMA PROD_USER; do
  if ! valid_name "${!v}"; then bad "$v='${!v}' is not a valid Oracle name"; settings_ok=0; fi
done
for v in PROD_PASSWORD LOCAL_SYS_PASSWORD; do
  if [[ "${!v}" == *\"* ]]; then bad "$v contains a double quote (\"), which is not supported"; settings_ok=0; fi
done
case "${ORACLE_VERSION:-23}" in
  11 | 12 | 18 | 19 | 21 | 23) ;;
  *) bad "ORACLE_VERSION='${ORACLE_VERSION}' is not supported"; hint "use 11, 12, 18, 19, 21 or 23"; settings_ok=0 ;;
esac
if [[ -n "${PROD_TNS:-}" ]]; then
  if [[ ! -f "${TNS_ADMIN:-}/tnsnames.ora" ]]; then
    bad "PROD_TNS is set but ${TNS_ADMIN:-TNS_ADMIN}/tnsnames.ora does not exist"; hint "set TNS_ADMIN to the folder with tnsnames.ora (absolute path)"; settings_ok=0
  elif ! tns_descriptor "$PROD_TNS" "$TNS_ADMIN/tnsnames.ora" >/dev/null; then
    bad "alias $PROD_TNS not found in $TNS_ADMIN/tnsnames.ora"; settings_ok=0
  fi
elif ! problem="$(check_connect_target "$PROD_CONNECT")"; then
  bad "$problem"; settings_ok=0
fi
if ((!settings_ok)); then finish; fi
ok "settings are valid"
resolve_settings

echo
echo "Docker"
if ! docker info >/dev/null 2>&1; then bad "Docker is not running"; hint "start Docker Desktop"; finish; fi
ok "Docker is running"
ensure_network
ensure_sqlcl_image

echo
echo "Prod ($(prod_conn_string) as $PROD_USER)"
schema="$(upper "$APP_SCHEMA")"
out="$(sqlcl_prod 2>&1 <<SQL
set heading off feedback off pagesize 0 serveroutput on
prompt __BEGIN__
select 'USER|' || user from dual;
select 'SCHEMA|' || count(*) from all_users where username = '$schema';
select 'TABLES|' || count(*) from all_tables where owner = '$schema';
select 'PACKAGES|' || count(*) from all_objects where owner = '$schema' and object_type = 'PACKAGE';
select 'BODIES|' || count(*) from all_objects where owner = '$schema' and object_type = 'PACKAGE BODY';
exec dbms_output.put_line('VERSION|' || dbms_db_version.version || '.' || dbms_db_version.release)
prompt __END__
SQL
)"
rc=$?
if ((rc != 0)) || [[ "$out" != *__BEGIN__* ]]; then
  bad "cannot log in to prod"
  printf '%s\n' "$out" | grep -E 'ORA-|IO Error|Error|refused|host' | head -3 | sed 's/^/      /'
  hint "$(printf '%s\n' "$out" | explain_connect_error)"
  finish
fi
info="$(printf '%s\n' "$out" | between_markers | tr -d ' ')"
field() { printf '%s\n' "$info" | sed -n "s/^$1|//p" | head -1; }
version="$(field VERSION)"
ok "logged in as $(field USER) (Oracle ${version:-?})"
major="${version%%.*}"
if [[ -n "$major" && "$major" != "${ORACLE_VERSION:-23}" ]]; then
  warn "ORACLE_VERSION=${ORACLE_VERSION:-23} but prod is Oracle $major"; hint "set ORACLE_VERSION=$major in .env"
fi
if [[ "$(field SCHEMA)" != 1 ]]; then
  bad "schema $schema not found on prod"; hint "check APP_SCHEMA in .env"
else
  ok "schema $schema: $(field TABLES) tables, $(field PACKAGES) packages"
  if [[ "$(field PACKAGES)" == 0 ]]; then
    warn "no packages visible in $schema"
    hint "if PROD_USER does not own the schema it needs more privileges (docs/vi/cau-hinh.md)"
  elif [[ "$(field BODIES)" -lt "$(field PACKAGES)" && "$(upper "$PROD_USER")" != "$schema" ]]; then
    warn "only $(field BODIES) of $(field PACKAGES) package bodies are visible to $PROD_USER"
    hint "PROD_USER needs privileges to read package bodies (docs/vi/cau-hinh.md)"
  fi
fi

echo
echo "Local database ($LOCAL_HOST, localhost:$LOCAL_PORT)"
state="$(docker inspect -f '{{.State.Status}}' "$LOCAL_HOST" 2>/dev/null || echo "not created")"
if [[ "$state" != running ]]; then
  warn "not running ($state): local checks skipped"; hint "make up, then make check again"
  finish
fi
ok "running"
using="$(prod_link_using)"
using_sql="${using//\'/\'\'}"
out="$(sqlcl_local system 2>&1 <<SQL
begin execute immediate 'drop database link PLSQL_CHECK_LINK'; exception when others then null; end;
/
create database link PLSQL_CHECK_LINK connect to $PROD_USER identified by "$PROD_PASSWORD" using '$using_sql';
set heading off feedback off pagesize 0
prompt __BEGIN__
select 'LINK_OK' from dual@PLSQL_CHECK_LINK;
select 'LOCAL_SCHEMA|' || count(*) from dba_users where username = '$schema';
prompt __END__
rollback;
begin execute immediate 'drop database link PLSQL_CHECK_LINK'; exception when others then null; end;
/
SQL
)"
rc=$?
if ((rc != 0)); then
  bad "cannot log in to the local DB as SYSTEM"
  hint "LOCAL_SYS_PASSWORD changed after the DB was created? run make reset-local && make up"
  finish
fi
local_info="$(printf '%s\n' "$out" | between_markers | tr -d ' ')"
if [[ "$local_info" == *LINK_OK* ]]; then
  ok "can reach prod from the local DB (needed by make sync)"
else
  bad "the local DB cannot reach prod (make sync would fail)"
  printf '%s\n' "$out" | redact_secrets | grep -E 'ORA-' | head -2 | sed 's/^/      /'
  hint "$(printf '%s\n' "$out" | explain_connect_error)"
  hint "the local DB runs in Docker: localhost there is the container; use host.docker.internal for a database on this machine"
fi
if [[ "$local_info" != *LOCAL_SCHEMA\|1* ]]; then
  warn "schema $schema is not in the local DB yet"; hint "run make sync"
fi
finish
