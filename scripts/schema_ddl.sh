#!/usr/bin/env bash
# Export the DDL (no data, no packages) of the local schema into ci/schema/.
# The PR check rebuilds the schema from these files to compile packages.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
resolve_settings
require_vars APP_SCHEMA LOCAL_SYS_PASSWORD
validate_identifier "$APP_SCHEMA" schema
schema="$(upper "$APP_SCHEMA")"
ensure_network
ensure_sqlcl_image

out="$(sqlcl_local system <<SQL
set heading off feedback off pagesize 0 linesize 32767 long 10000000 longchunksize 32767 trimout on verify off
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
prompt __FILE__ 01_sequences.sql
select dbms_metadata.get_ddl('SEQUENCE', sequence_name, sequence_owner) from all_sequences
 where sequence_owner = '$schema' and sequence_name not like 'ISEQ\$\$%' order by sequence_name;
prompt __FILE__ 02_types.sql
select dbms_metadata.get_ddl('TYPE_SPEC', object_name, owner) from all_objects
 where owner = '$schema' and object_type = 'TYPE' order by created, object_name;
prompt __FILE__ 03_tables.sql
select dbms_metadata.get_ddl('TABLE', table_name, owner) from all_tables
 where owner = '$schema' and nested = 'NO' and secondary = 'N' and table_name not like 'BIN\$%'
   and (iot_type is null or iot_type = 'IOT') order by table_name;
prompt __FILE__ 04_ref_constraints.sql
select dbms_metadata.get_ddl('REF_CONSTRAINT', constraint_name, owner) from all_constraints
 where owner = '$schema' and constraint_type = 'R' order by table_name, constraint_name;
prompt __FILE__ 05_views.sql
select dbms_metadata.get_ddl('VIEW', view_name, owner) from all_views
 where owner = '$schema' order by view_name;
prompt __FILE__ 06_synonyms.sql
select dbms_metadata.get_ddl('SYNONYM', synonym_name, owner) from all_synonyms
 where owner = '$schema' order by synonym_name;
prompt __FILE__ 07_routines.sql
select dbms_metadata.get_ddl(object_type, object_name, owner) from all_objects
 where owner = '$schema' and object_type in ('FUNCTION', 'PROCEDURE') order by object_type, object_name;
prompt __END__
SQL
)" || die "cannot connect to the local DB (run: make up)" 2

if printf '%s\n' "$out" | grep -E '^(ORA|SP2)-[0-9]+' >/dev/null; then
  printf '%s\n' "$out" | grep -E '^(ORA|SP2)-[0-9]+' >&2
  echo "warning: some DDL could not be exported (see errors above)" >&2
fi

tmp="$(mktemp -d)"
printf '%s\n' "$out" | between_markers | awk -v dir="$tmp" '
  /^__FILE__ / { f = dir "/" $2; printf "" > f; next }
  f != "" { print > f }'

mkdir -p "$REPO_ROOT/ci/schema"
rm -f "$REPO_ROOT"/ci/schema/*.sql
for f in "$tmp"/*.sql; do
  name="$(basename "$f")"
  clean_ddl < "$f" > "$REPO_ROOT/ci/schema/$name"
  if [[ ! -s "$REPO_ROOT/ci/schema/$name" ]]; then rm -f "$REPO_ROOT/ci/schema/$name"; fi
done
rm -rf "$tmp"
echo "schema DDL written to ci/schema/ (commit it when it changes)"
