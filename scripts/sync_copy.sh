#!/usr/bin/env bash
# Copy-mode sync: rebuild the local schema from prod without Data Pump.
# DDL comes from DBMS_METADATA.GET_DDL on prod; rows are copied with
# INSERT ... SELECT over a temporary database link, per the data scope file.
# Foreign keys, parent rows and identity columns are handled afterwards by
# sync_relations.sh (shared with the Data Pump path).
# Used when Data Pump cannot run against prod (for example Oracle Free "lite"
# images, which ship without the XDB library Data Pump needs).
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
scope_file="$(data_scope_file)"
where_fn="$(scope_to_where "$scope_file")" || die "fix $scope_file and retry"
using="$(prod_link_using)"
using_sql="${using//\'/\'\'}"
ensure_network
ensure_sqlcl_image

tmp="$(mktemp -d)"
drop_link() {
  sqlcl_local system >/dev/null 2>&1 <<'SQL' || true
begin
  execute immediate 'drop database link PLSQL_SYNC_LINK';
exception when others then null;
end;
/
SQL
  rm -rf "$tmp"
}
trap drop_link EXIT

# Run SQL on the local DB as SYSTEM; print ORA- errors as warnings.
apply_local() {
  local label="$1" out errors
  out="$(sqlcl_local system)" || die "cannot connect to the local DB (run: make up)" 2
  errors="$(printf '%s\n' "$out" | grep -E '^(ORA|SP2|PLS)-[0-9]+' || true)"
  if [[ -n "$errors" ]]; then
    echo "warning: some statements failed while creating $label:" >&2
    printf '%s\n' "$errors" | sort | uniq -c >&2
  fi
}

# Concatenate the DDL files of a phase (missing files are skipped).
phase() {
  local f
  for f in "$@"; do
    if [[ -f "$tmp/$f" ]]; then cat "$tmp/$f"; echo; fi
  done
}

echo "==> copy mode: reading object DDL from prod"
out="$(sqlcl_prod <<SQL
set serveroutput on size unlimited
set heading off feedback off pagesize 0 linesize 32767 trimout on
begin
  dbms_metadata.set_transform_param(dbms_metadata.session_transform, 'SEGMENT_ATTRIBUTES', false);
  dbms_metadata.set_transform_param(dbms_metadata.session_transform, 'STORAGE', false);
  dbms_metadata.set_transform_param(dbms_metadata.session_transform, 'TABLESPACE', false);
  dbms_metadata.set_transform_param(dbms_metadata.session_transform, 'REF_CONSTRAINTS', false);
  dbms_metadata.set_transform_param(dbms_metadata.session_transform, 'SQLTERMINATOR', true);
  dbms_metadata.set_transform_param(dbms_metadata.session_transform, 'PRETTY', true);
end;
/
prompt __BEGIN__
declare
  procedure put_clob(c clob) is
    pos pls_integer := 1;
    nl  pls_integer;
    len pls_integer := dbms_lob.getlength(c);
  begin
    while pos <= len loop
      nl := dbms_lob.instr(c, chr(10), pos);
      if nl = 0 then nl := len + 1; end if;
      dbms_output.put_line(dbms_lob.substr(c, least(nl - pos, 32000), pos));
      pos := nl + 1;
    end loop;
  end;
  procedure ddl(p_type varchar2, p_name varchar2) is
  begin
    put_clob(dbms_metadata.get_ddl(p_type, p_name, '$schema'));
  exception when others then
    dbms_output.put_line('-- warning: could not read ' || p_type || ' ' || p_name || ': ' || sqlerrm);
  end;
  procedure file(p_name varchar2) is
  begin
    dbms_output.put_line('__FILE__ ' || p_name);
  end;
begin
  file('10_sequences.sql');
  for o in (select sequence_name n from all_sequences
             where sequence_owner = '$schema' and sequence_name not like 'ISEQ\$\$%' order by 1) loop
    ddl('SEQUENCE', o.n);
  end loop;
  file('20_types.sql');
  for o in (select object_name n from all_objects
             where owner = '$schema' and object_type = 'TYPE' order by created, object_name) loop
    ddl('TYPE_SPEC', o.n);
  end loop;
  file('30_tables.sql');
  for o in (select table_name n from all_tables
             where owner = '$schema' and nested = 'NO' and secondary = 'N' and table_name not like 'BIN\$%'
               and (iot_type is null or iot_type = 'IOT') $(only_filter table_name) order by 1) loop
    ddl('TABLE', o.n);
  end loop;
  file('50_indexes.sql');
  for o in (select i.index_name n from all_indexes i
             where i.owner = '$schema' and i.index_type not like '%LOB%' and i.table_owner = '$schema'
               and not exists (select 1 from all_constraints c
                                where c.owner = i.owner and c.index_name = i.index_name)
               $(only_filter i.table_name)
             order by 1) loop
    ddl('INDEX', o.n);
  end loop;
  file('60_views.sql');
  for o in (select view_name n from all_views where owner = '$schema' order by 1) loop
    ddl('VIEW', o.n);
  end loop;
  file('70_synonyms.sql');
  for o in (select synonym_name n from all_synonyms where owner = '$schema' order by 1) loop
    ddl('SYNONYM', o.n);
  end loop;
  file('80_type_bodies.sql');
  for o in (select object_name n from all_objects where owner = '$schema' and object_type = 'TYPE BODY' order by 1) loop
    ddl('TYPE_BODY', o.n);
  end loop;
  file('81_routines.sql');
  for o in (select object_type t, object_name n from all_objects
             where owner = '$schema' and object_type in ('FUNCTION', 'PROCEDURE') order by 1, 2) loop
    ddl(o.t, o.n);
  end loop;
  file('82_package_specs.sql');
  for o in (select object_name n from all_objects where owner = '$schema' and object_type = 'PACKAGE' order by 1) loop
    ddl('PACKAGE_SPEC', o.n);
  end loop;
  file('83_package_bodies.sql');
  for o in (select object_name n from all_objects where owner = '$schema' and object_type = 'PACKAGE BODY' order by 1) loop
    ddl('PACKAGE_BODY', o.n);
  end loop;
  file('90_triggers.sql');
  for o in (select trigger_name n from all_triggers where owner = '$schema' order by 1) loop
    ddl('TRIGGER', o.n);
  end loop;
end;
/
prompt __END__
SQL
)" || die "could not read from prod" 2
printf '%s\n' "$out" | between_markers | awk -v dir="$tmp" '
  /^__FILE__ / { f = dir "/" $2; printf "" > f; next }
  f != "" { print > f }'
if [[ ! -f "$tmp/30_tables.sql" ]]; then
  printf '%s\n' "$out" | redact_secrets >&2
  die "could not read the schema DDL from prod"
fi
grep -h '^-- warning' "$tmp"/*.sql >&2 || true

echo "==> recreating local schema $schema"
recreate_local_schema "$schema"

echo "==> creating sequences, types and tables"
# Rows keep their prod identity values, so load identity columns BY DEFAULT.
phase 10_sequences.sql 20_types.sql 30_tables.sql \
  | sed 's/GENERATED ALWAYS AS IDENTITY/GENERATED BY DEFAULT AS IDENTITY/' \
  | apply_local "tables"

echo "==> creating a temporary database link to prod"
out="$(sqlcl_local system <<SQL
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

echo "==> copying rows (per $scope_file)"
out="$(sqlcl_local system <<SQL
set serveroutput on size unlimited
set heading off feedback off pagesize 0 linesize 32767
prompt __BEGIN__
declare
  function rule_for(p_table varchar2) return varchar2 is
  begin
$where_fn
  end;
  procedure copy_table(p_table varchar2) is
    cols varchar2(32767);
    w    varchar2(4000) := rule_for(p_table);
    n    number;
  begin
    if w = 'NONE' then
      dbms_output.put_line('. . skipped "$schema"."' || p_table || '" (NONE)');
      return;
    end if;
    select listagg('"' || column_name || '"', ', ') within group (order by column_id) into cols
      from all_tab_cols
     where owner = '$schema' and table_name = p_table
       and virtual_column = 'NO' and hidden_column = 'NO' and data_type not in ('LONG', 'LONG RAW');
    execute immediate 'insert into "$schema"."' || p_table || '" (' || cols || ') select ' || cols
      || ' from "$schema"."' || p_table || '"@PLSQL_SYNC_LINK ' || w;
    n := sql%rowcount;
    commit;
    dbms_output.put_line('. . copied "$schema"."' || p_table || '" ' || n || ' rows');
  exception when others then
    rollback;
    dbms_output.put_line('warning: could not copy ' || p_table || ': ' || sqlerrm);
  end;
begin
  for t in (select table_name from all_tables
             where owner = '$schema' and nested = 'NO' and secondary = 'N' and temporary = 'N'
               and (iot_type is null or iot_type = 'IOT') $(only_filter table_name) order by table_name) loop
    copy_table(t.table_name);
  end loop;
end;
/
prompt __END__
SQL
)" || die "lost the connection to the local DB while copying" 2
printf '%s\n' "$out" | between_markers | grep -v '^[[:space:]]*$' || true

if [[ -n "${ONLY_TABLES:-}" ]]; then
  echo "==> creating indexes (partial sync: views, code and triggers skipped)"
  phase 50_indexes.sql | apply_local "indexes"
else
  echo "==> creating indexes, views, code and triggers"
  phase 50_indexes.sql 60_views.sql 70_synonyms.sql 80_type_bodies.sql \
    81_routines.sql 82_package_specs.sql 83_package_bodies.sql 90_triggers.sql \
    | apply_local "dependent objects"
fi

echo "copy mode finished"
