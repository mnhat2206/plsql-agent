#!/usr/bin/env bash
# Compile packages, functions and procedures from src/ into the local DB (default) or prod.
# usage: compile.sh [--target local|prod] [name ...]   (packages, functions, procedures)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
resolve_settings

target=local
if [[ "${1:-}" == "--target" ]]; then
  target="${2:-}"
  shift 2
fi
case "$target" in
  local) require_vars APP_SCHEMA LOCAL_SYS_PASSWORD ;;
  prod) require_vars APP_SCHEMA PROD_USER PROD_PASSWORD; require_prod_target ;;
  *) die "unknown target '$target' (use local or prod)" ;;
esac
validate_identifier "$APP_SCHEMA" schema
schema="$(upper "$APP_SCHEMA")"
cd "$REPO_ROOT"

objs=()
if (($# > 0)); then
  for p in "$@"; do
    validate_identifier "$p" name
    objs+=("$(lower "$p")")
  done
else
  while IFS= read -r p; do
    if [[ -n "$p" ]]; then objs+=("$p"); fi
  done <<EOF
$(source_files | while IFS= read -r f; do source_name "$f"; done | sort -u)
EOF
fi
if ((${#objs[@]} == 0)); then
  echo "nothing to compile"
  exit 0
fi
bad=0
files=()
for p in "${objs[@]}"; do
  found="$(object_files "$p")"
  if [[ -z "$found" ]]; then die "no source for $p in src/packages, src/functions or src/procedures"; fi
  while IFS= read -r f; do
    files+=("$f")
    if ! validate_source_file "$f"; then bad=1; fi
  done <<EOF
$found
EOF
done
if ((bad)); then die "fix the files above; nothing was compiled"; fi
ensure_network
ensure_sqlcl_image

names=""
for p in "${objs[@]}"; do names="$names,'$(upper "$p")'"; done
names="${names#,}"

# Package specs first, then standalone functions and procedures, then package
# bodies; whatever is still INVALID afterwards (mutual calls) is recompiled.
script="$(
  echo "alter session set current_schema = $schema;"
  for ext in pks fnc prc pkb; do
    for f in "${files[@]}"; do
      if [[ "$f" == *."$ext" ]]; then echo "@$f"; fi
    done
  done
  cat <<SQL
begin
  for pass in 1 .. 2 loop
    for o in (select object_name, object_type from all_objects
               where owner = '$schema' and object_name in ($names)
                 and object_type in ('PACKAGE', 'PACKAGE BODY', 'FUNCTION', 'PROCEDURE')
                 and status = 'INVALID') loop
      begin
        execute immediate 'alter '
          || case when o.object_type = 'PACKAGE BODY' then 'package' else lower(o.object_type) end
          || ' "$schema"."' || o.object_name || '" compile'
          || case when o.object_type = 'PACKAGE BODY' then ' body' end;
      exception when others then null;
      end;
    end loop;
  end loop;
end;
/
set heading off feedback off pagesize 0 linesize 32767
prompt __BEGIN__
select name || '|' || type || '|' || line || '|' || position || '|' || replace(replace(text, chr(10), ' '), '|', '/')
  from all_errors
 where owner = '$schema' and name in ($names) and attribute = 'ERROR'
 order by name, type, sequence;
select 'INVALID|' || object_name || '|' || object_type from all_objects
 where owner = '$schema' and object_name in ($names)
   and object_type in ('PACKAGE', 'PACKAGE BODY', 'FUNCTION', 'PROCEDURE') and status = 'INVALID'
 order by object_name, object_type;
prompt __END__
SQL
)"

rc=0
if [[ "$target" == local ]]; then
  out="$(printf '%s\n' "$script" | sqlcl_local "$APP_SCHEMA")" || rc=$?
else
  out="$(printf '%s\n' "$script" | sqlcl_prod)" || rc=$?
fi
if ((rc != 0)); then die "cannot connect to the $target database" 2; fi

before="$(printf '%s\n' "$out" | awk '/^__BEGIN__/ { exit } { print }')"
problems="$(printf '%s\n' "$out" | between_markers | grep -v '^[[:space:]]*$' || true)"
ora="$(printf '%s\n' "$before" | grep -E '^(ORA|SP2|PLS)-[0-9]+' || true)"
printf '%s\n' "$before" | grep -v '^[[:space:]]*$' || true

if [[ -n "$problems" || -n "$ora" ]]; then
  echo "compile failed ($target):" >&2
  if [[ -n "$problems" ]]; then printf '%s\n' "$problems" | format_errors >&2; fi
  if [[ -n "$ora" ]]; then printf '%s\n' "$ora" >&2; fi
  exit 1
fi
echo "compiled OK ($target): ${objs[*]}"
