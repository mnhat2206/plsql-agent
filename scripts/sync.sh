#!/usr/bin/env bash
# Copy the prod schema (all structure + data per the data scope file) into the
# local DB over a temporary database link. Nothing is written on prod.
# SYNC_MODE: auto (default: Data Pump, falling back to copy mode), datapump, copy.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
resolve_settings
require_vars APP_SCHEMA PROD_USER PROD_PASSWORD LOCAL_SYS_PASSWORD
require_prod_target
validate_identifier "$APP_SCHEMA" schema
validate_identifier "$PROD_USER" "prod user"
schema="$(upper "$APP_SCHEMA")"

mode="${SYNC_MODE:-auto}"
case "$mode" in
  auto | datapump | copy) ;;
  *) die "unknown SYNC_MODE '$mode' (use auto, datapump or copy)" ;;
esac
scope_file="$(data_scope_file)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
if scope_uses_used "$scope_file"; then
  echo "==> finding the tables the packages use (USED)"
  prod_used_tables > "$work/used.txt" || die "could not read dependencies from prod" 2
  expand_used_scope "$scope_file" "$work/used.txt" > "$work/scope.conf"
  echo "    $(grep -c . "$work/used.txt" || true) table(s) used by packages"
  scope_file="$work/scope.conf"
  export DATA_SCOPE="$scope_file"
fi
filters="$(scope_to_plsql "$scope_file" "$schema")" || die "fix $scope_file and retry"

# Partial sync: only these tables (and their parent tables), no code objects.
dp_only=""
excluded="''DB_LINK'', ''JOB'', ''PROCOBJ'', ''REF_CONSTRAINT''"
if [[ -n "${ONLY:-}" ]]; then
  names=()
  for t in $ONLY; do validate_identifier "$t" table; names+=("$(upper "$t")"); done
  ensure_network
  ensure_sqlcl_image
  ONLY_TABLES="$(prod_tables_with_parents "${names[@]}" | paste -sd, -)" || die "could not read from prod" 2
  [[ -n "$ONLY_TABLES" ]] || die "none of these tables exist in $schema on prod: ${names[*]}"
  export ONLY_TABLES
  echo "==> partial sync: ${ONLY_TABLES//,/, } (listed tables and their parent tables)"
  dp_only="  DBMS_DATAPUMP.METADATA_FILTER(h, 'NAME_EXPR', 'IN ($(printf '%s' "$ONLY_TABLES" | sed "s/[^,][^,]*/''&''/g"))', 'TABLE');"
  excluded="$excluded, ''VIEW'', ''SYNONYM'', ''FUNCTION'', ''PROCEDURE'', ''PACKAGE'', ''TRIGGER''"
fi
using="$(prod_link_using)"
using_sql="${using//\'/\'\'}"
ensure_network
ensure_sqlcl_image

# Data Pump rule: a privileged importer needs a privileged source user. When the
# prod user owns the schema, import as the (unprivileged) local schema owner.
if [[ "$(upper "$PROD_USER")" == "$schema" ]]; then importer="$schema"; else importer=system; fi

drop_link() {
  sqlcl_local "$importer" >/dev/null 2>&1 <<'SQL' || true
begin
  execute immediate 'drop database link PLSQL_SYNC_LINK';
exception when others then null;
end;
/
SQL
}

# Returns 1 when the Data Pump job does not complete.
datapump_import() {
echo "==> recreating local schema $schema"
recreate_local_schema "$schema"

echo "==> creating a temporary database link to prod (as $importer)"
drop_link
trap 'drop_link; rm -rf "$work"' EXIT
out="$(sqlcl_local "$importer" <<SQL
create database link PLSQL_SYNC_LINK connect to $PROD_USER identified by "$PROD_PASSWORD" using '$using_sql';
set heading off feedback off pagesize 0
prompt __BEGIN__
select 'LINK_OK' from dual@PLSQL_SYNC_LINK;
prompt __END__
SQL
)" || die "cannot connect to the local DB (run: make up)" 2
if ! printf '%s\n' "$out" | between_markers | grep LINK_OK >/dev/null; then
  printf '%s\n' "$out" | redact_secrets >&2
  die "the local DB cannot reach prod through the database link (check PROD_CONNECT, credentials and that Docker can reach the prod host)" 2
fi

echo "==> importing $schema from prod with Data Pump (this can take a while)"
out="$(sqlcl_local "$importer" <<SQL
set serveroutput on size unlimited
set heading off feedback off pagesize 0 linesize 32767
prompt __BEGIN__
declare
  h     number;
  state varchar2(30) := 'UNDEFINED';
  sts   ku\$_Status;
  le    ku\$_LogEntry;
begin
  h := DBMS_DATAPUMP.OPEN(operation => 'IMPORT', job_mode => 'SCHEMA',
                          remote_link => 'PLSQL_SYNC_LINK', version => '$DP_VERSION');
  DBMS_DATAPUMP.METADATA_FILTER(h, 'SCHEMA_EXPR', 'IN (''$schema'')');
  DBMS_DATAPUMP.METADATA_FILTER(h, 'EXCLUDE_PATH_EXPR', 'IN ($excluded)');
$dp_only
  DBMS_DATAPUMP.METADATA_TRANSFORM(h, 'SEGMENT_ATTRIBUTES', 0);
  DBMS_DATAPUMP.SET_PARAMETER(h, 'TABLE_EXISTS_ACTION', 'REPLACE');
$filters
  DBMS_DATAPUMP.START_JOB(h);
  while state not in ('COMPLETED', 'STOPPED') loop
    DBMS_DATAPUMP.GET_STATUS(h, DBMS_DATAPUMP.KU\$_STATUS_JOB_ERROR + DBMS_DATAPUMP.KU\$_STATUS_JOB_STATUS
                               + DBMS_DATAPUMP.KU\$_STATUS_WIP, -1, state, sts);
    le := null;
    if bitand(sts.mask, DBMS_DATAPUMP.KU\$_STATUS_WIP) != 0 then
      le := sts.wip;
    elsif bitand(sts.mask, DBMS_DATAPUMP.KU\$_STATUS_JOB_ERROR) != 0 then
      le := sts.error;
    end if;
    if le is not null and le.count > 0 then
      for i in le.first .. le.last loop
        dbms_output.put_line(le(i).LogText);
      end loop;
    end if;
  end loop;
  dbms_output.put_line('__STATE__ ' || state);
  DBMS_DATAPUMP.DETACH(h);
exception
  when others then
    dbms_output.put_line('__STATE__ FAILED ' || sqlerrm);
    begin DBMS_DATAPUMP.STOP_JOB(h); exception when others then null; end;
end;
/
prompt __END__
SQL
)" || die "lost the connection to the local DB during import" 2

log="$(printf '%s\n' "$out" | between_markers || true)"
printf '%s\n' "$log" | grep -v '^__STATE__' || true
state="$(printf '%s\n' "$log" | sed -n 's/^__STATE__ //p')"
drop_link
trap 'rm -rf "$work"' EXIT
if [[ "$state" != COMPLETED ]]; then
  echo "Data Pump import did not complete (${state:-no state reported})" >&2
  return 1
fi
}

if [[ "$mode" == copy ]]; then
  "$SCRIPT_DIR/sync_copy.sh"
elif ! datapump_import; then
  if [[ "$mode" == datapump ]]; then die "Data Pump import failed (SYNC_MODE=datapump)"; fi
  echo "==> Data Pump is not usable against this prod; falling back to copy mode (GET_DDL + INSERT ... SELECT)"
  "$SCRIPT_DIR/sync_copy.sh"
fi
"$SCRIPT_DIR/sync_relations.sh"

size_mb="$(sqlcl_local system <<SQL | between_markers | tr -d '[:space:]'
set heading off feedback off pagesize 0
prompt __BEGIN__
select nvl(round(sum(bytes) / 1024 / 1024), 0) from dba_segments where owner = '$schema';
prompt __END__
SQL
)" || true
if [[ ! "$size_mb" =~ ^[0-9]+$ ]]; then size_mb=0; fi
echo "==> local schema size: ${size_mb} MB"
if ((size_mb > 10240)); then
  echo "warning: close to the ~11-12 GB user data limit of Oracle Free/XE; narrow $scope_file" >&2
fi

if [[ -n "${ONLY_TABLES:-}" ]]; then
  echo "partial sync done (ci/schema/ left unchanged). Run make sync without ONLY for the whole schema."
  exit 0
fi
echo "==> exporting schema DDL to ci/schema/"
"$SCRIPT_DIR/schema_ddl.sh"
echo "sync done. Commit ci/schema/ if it changed."
