#!/usr/bin/env bash
# Shared helpers for every script. Source it; do not execute it.
# Must stay compatible with bash 3.2 (macOS) and POSIX awk/sed.

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

die() {
  echo "error: $1" >&2
  exit "${2:-1}"
}

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Export KEY=VALUE pairs from a .env file. Variables already set in the
# environment win (CI passes secrets that way). Values are literal.
load_env() {
  local file="${1:-$REPO_ROOT/.env}" line key value
  local re_kv='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
  local re_dq='^"(.*)"[[:space:]]*(#.*)?$'
  local re_sq="^'(.*)'[[:space:]]*(#.*)?\$"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ $re_kv ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ "$value" =~ $re_dq ]] || [[ "$value" =~ $re_sq ]]; then
      value="${BASH_REMATCH[1]}"
    else
      value="${value%%[[:space:]]#*}"
      value="${value%"${value##*[![:space:]]}"}"
    fi
    if [[ -z "${!key+x}" ]]; then
      export "$key=$value"
    fi
  done < "$file"
}

require_vars() {
  local v missing=""
  for v in "$@"; do
    if [[ -z "${!v:-}" ]]; then missing="$missing $v"; fi
  done
  if [[ -n "$missing" ]]; then
    die "missing config:$missing (set it in .env or the environment)"
  fi
}

validate_identifier() {
  local re='^[A-Za-z][A-Za-z0-9_$#]*$'
  if [[ ! "$1" =~ $re ]]; then
    die "invalid ${2:-name}: '$1'"
  fi
}

# Resolve runtime settings (call after load_env).
resolve_settings() {
  local v="${ORACLE_VERSION:-23}" image dp
  case "$v" in
    23 | 19) image=gvenzl/oracle-free:23-slim ;;
    21 | 18 | 12) image=gvenzl/oracle-xe:21-slim ;;
    11) image=gvenzl/oracle-xe:18-slim ;;
    *) die "unsupported ORACLE_VERSION '$v' (use 11, 12, 18, 19, 21 or 23)" ;;
  esac
  case "$v" in
    23) dp=COMPATIBLE ;;
    12) dp=12.2.0 ;;
    11) dp=11.2.0 ;;
    *) dp="$v.0.0" ;;
  esac
  LOCAL_IMAGE="${LOCAL_IMAGE:-$image${LOCAL_IMAGE_SUFFIX:-}}"
  if [[ -z "${LOCAL_SERVICE:-}" ]]; then
    case "$LOCAL_IMAGE" in
      *oracle-free*) LOCAL_SERVICE=FREEPDB1 ;;
      *) LOCAL_SERVICE=XEPDB1 ;;
    esac
  fi
  DP_VERSION="$dp"
  SQLCL_IMAGE="${SQLCL_IMAGE:-plsql-sqlcl:${SQLCL_VERSION:-latest}}"
  DOCKER_NETWORK="${DOCKER_NETWORK:-plsql}"
  COMPOSE_PROJECT="${COMPOSE_PROJECT:-plsql}"
  LOCAL_HOST="${LOCAL_HOST:-oracle-local}"
  LOCAL_PORT="${LOCAL_PORT:-1530}"
  export LOCAL_IMAGE LOCAL_SERVICE DP_VERSION SQLCL_IMAGE DOCKER_NETWORK \
    COMPOSE_PROJECT LOCAL_HOST LOCAL_PORT
}

# ---------------------------------------------------------------------------
# Text helpers
# ---------------------------------------------------------------------------

# Canonical form of a package source file. Used for both pulled files and
# git files so that comparisons are stable.
normalize_source() {
  awk '
    function strip_create(s,   low) {
      low = tolower(s)
      if (match(low, /^create([[:blank:]]+or[[:blank:]]+replace)?([[:blank:]]+(non)?editionable)?([[:blank:]]+|$)/))
        return substr(s, RLENGTH + 1)
      return s
    }
    { sub(/\r$/, ""); sub(/[[:blank:]]+$/, ""); lines[++n] = $0 }
    END {
      # Oracle stores source from the PACKAGE keyword on: skip blank lines and
      # "--" comments before CREATE, and join a CREATE header split over lines.
      first = 1
      while (first <= n && (lines[first] == "" || lines[first] ~ /^[[:blank:]]*--/)) first++
      last = n
      while (last >= first && (lines[last] == "" || lines[last] == "/")) last--
      if (first > last) exit
      head = lines[first]
      sub(/^[[:blank:]]+/, "", head)
      while (first < last && tolower(head) ~ /^create/ && strip_create(head) == "") {
        t = lines[++first]
        sub(/^[[:blank:]]+/, "", t)
        head = head " " t
      }
      print "CREATE OR REPLACE " strip_create(head)
      for (i = first + 1; i <= last; i++) print lines[i]
      print "/"
    }'
}

between_markers() {
  awk '
    /^__BEGIN__[[:blank:]]*$/ { on = 1; found = 1; next }
    /^__END__[[:blank:]]*$/ { on = 0; next }
    on { print }
    END { exit found ? 0 : 2 }'
}

# Print the connect descriptor of a tnsnames.ora alias, whitespace removed.
tns_descriptor() {
  awk -v alias="$1" '
    { sub(/#.*/, ""); text = text " " $0 }
    END {
      a = toupper(alias); name = ""; i = 1; L = length(text)
      while (i <= L) {
        c = substr(text, i, 1)
        if (c != "=") { name = name c; i++; continue }
        key = toupper(name); gsub(/[[:blank:]]/, "", key); name = ""
        j = i + 1
        while (j <= L && substr(text, j, 1) ~ /[[:blank:]]/) j++
        d = 0
        for (k = j; k <= L; k++) {
          ch = substr(text, k, 1)
          if (ch == "(") d++
          else if (ch == ")") { d--; if (d == 0) break }
        }
        val = substr(text, j, k - j + 1)
        nk = split(key, keys, ",")
        for (m = 1; m <= nk; m++) {
          if (keys[m] == a || index(keys[m], a ".") == 1) {
            gsub(/[[:blank:]]+/, "", val); print val; found = 1; exit
          }
        }
        i = k + 1
      }
      exit found ? 0 : 1
    }' "$2"
}

# NAME|TYPE|LINE|POS|TEXT  ->  src/packages/name.pkb:LINE:POS: TEXT
format_errors() {
  awk -F'|' '
    { sub(/[[:blank:]]+$/, "") }
    $1 == "INVALID" && NF >= 3 { print $2 " (" $3 ") is INVALID"; next }
    NF >= 5 {
      if ($2 == "PACKAGE BODY") path = "src/packages/" tolower($1) ".pkb"
      else if ($2 == "FUNCTION") path = "src/functions/" tolower($1) ".fnc"
      else if ($2 == "PROCEDURE") path = "src/procedures/" tolower($1) ".prc"
      else path = "src/packages/" tolower($1) ".pks"
      text = $5
      for (i = 6; i <= NF; i++) text = text "|" $i
      print path ":" $3 ":" $4 ": " text
    }'
}

# ---------------------------------------------------------------------------
# Data scope (config/data-scope.conf) -> DBMS_DATAPUMP.DATA_FILTER calls
# ---------------------------------------------------------------------------
_scope_awk() {
  awk -v mode="$1" -v schema="$2" '
    function q(s) { gsub(/\047/, "\047\047", s); return "\047" s "\047" }
    function filter(name, value, table) {
      if (table == "") print "  DBMS_DATAPUMP.DATA_FILTER(h, \047" name "\047, " value ");"
      else print "  DBMS_DATAPUMP.DATA_FILTER(h, \047" name "\047, " value ", " q(table) ", " q(schema) ");"
    }
    # Only SUBQUERY filters, plus a table-level INCLUDE_ROWS 0 for NONE: Data
    # Pump rejects a job-level INCLUDE_ROWS 0 next to table-level filters (ORA-39001).
    function emit(table, kind, arg) {
      if (kind == "FULL") {
        if (table != "") filter("SUBQUERY", q("WHERE 1=1"), table)
      } else if (kind == "NONE") {
        if (table == "") filter("SUBQUERY", q("WHERE 1=0"), table)
        else filter("INCLUDE_ROWS", 0, table)
      } else if (kind == "SAMPLE") {
        filter("SUBQUERY", q("WHERE ORA_HASH(ROWID, 99) < " arg), table)
      } else if (kind == "LIMIT") {
        filter("SUBQUERY", q("WHERE ROWNUM <= " arg), table)
      } else {
        filter("SUBQUERY", q("WHERE " arg), table)
      }
    }
    function bad(msg) { err = "data-scope: line " NR ": " msg; exit 2 }
    { sub(/\r$/, "") }
    /^[[:blank:]]*(#|$)/ { next }
    {
      line = $0; sub(/^[[:blank:]]+/, "", line)
      table = line; sub(/[[:blank:]].*$/, "", table)
      rest = substr(line, length(table) + 1); sub(/^[[:blank:]]+/, "", rest)
      kind = rest; sub(/[[:blank:]].*$/, "", kind); kind = toupper(kind)
      arg = substr(rest, length(kind) + 1); sub(/^[[:blank:]]+/, "", arg)
      if (kind != "WHERE") sub(/[[:blank:]]*#.*$/, "", arg)
      sub(/[[:blank:]]+$/, "", arg)
      if (table !~ /^[A-Za-z][A-Za-z0-9_$#]*$/) bad("invalid table name: " table)
      if (kind == "SAMPLE" && (arg !~ /^[0-9]+$/ || arg + 0 < 1 || arg + 0 > 99)) bad("SAMPLE needs a percentage 1-99 for " table)
      if (kind == "WHERE" && arg == "") bad("WHERE needs a condition for " table)
      if (kind == "LIMIT" && (arg !~ /^[0-9]+$/ || arg + 0 < 1)) bad("LIMIT needs a row count >= 1 for " table)
      if (kind != "FULL" && kind != "NONE" && kind != "SAMPLE" && kind != "WHERE" && kind != "LIMIT") bad("unknown rule " kind " for " table)
      if (mode == "where") {
        clause = (kind == "NONE") ? "NONE" : (kind == "SAMPLE") ? "WHERE ORA_HASH(ROWID, 99) < " arg : (kind == "LIMIT") ? "WHERE ROWNUM <= " arg : (kind == "WHERE") ? "WHERE " arg : ""
        if (toupper(table) == "DEFAULT") dflt = clause
        else print "    if p_table = " q(toupper(table)) " then return " q(clause) "; end if;"
      } else if (toupper(table) == "DEFAULT") emit("", kind, arg)
      else emit(toupper(table), kind, arg)
    }
    END {
      if (err != "") { print err > "/dev/stderr"; exit 2 }
      if (mode == "where") print "    return " q(dflt) ";"
    }
  ' "$3"
}

scope_to_plsql() { _scope_awk plsql "$2" "$1"; }

# data-scope.conf -> body of a PL/SQL function of p_table returning the WHERE
# clause to copy with, '' for all rows, or 'NONE' (copy-mode sync).
scope_to_where() { _scope_awk where "" "$1"; }

# ---------------------------------------------------------------------------
# Docker + SQLcl
# ---------------------------------------------------------------------------
ensure_network() {
  if ! docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
    docker network create "$DOCKER_NETWORK" >/dev/null
  fi
}

ensure_sqlcl_image() {
  if ! docker image inspect "$SQLCL_IMAGE" >/dev/null 2>&1; then
    echo "building $SQLCL_IMAGE (first run only)..." >&2
    docker build -q -t "$SQLCL_IMAGE" --build-arg "SQLCL_VERSION=${SQLCL_VERSION:-latest}" \
      -f "$REPO_ROOT/docker/sqlcl.Dockerfile" "$REPO_ROOT/docker" >/dev/null
  fi
}

# Run SQLcl with the SQL script given on stdin. Secrets travel on stdin only.
sqlcl_run() {
  local args=(run --rm -i --network "$DOCKER_NETWORK" -v "$REPO_ROOT":/work -w /work)
  if [[ -n "${TNS_ADMIN:-}" ]]; then
    args+=(-v "$TNS_ADMIN":/tns:ro -e TNS_ADMIN=/tns)
  fi
  docker "${args[@]}" "$SQLCL_IMAGE" sql -S /nolog
}

# sqlcl_session USER PASSWORD CONNECT < script
sqlcl_session() {
  local out
  out="$({
    printf 'whenever sqlerror continue\nset define off\nset trimout on\n'
    printf 'conn %s/"%s"@%s\n' "$1" "$2" "$3"
    printf 'set heading off feedback off\nselect %s from dual;\nset heading on feedback on\n' "'__CONNECTED__'"
    cat
    printf '\nexit\n'
  } | sqlcl_run 2>&1)" || true
  # Match in bash: "printf | grep -q" breaks the pipe on large output (pipefail).
  if [[ $'\n'"$out" != *$'\n__CONNECTED__'* ]]; then
    printf '%s\n' "$out" | redact_secrets >&2
    return 2
  fi
  printf '%s\n' "$out" | grep -v '^__CONNECTED__[[:space:]]*$' || true
}

sqlcl_local() {
  check_password LOCAL_SYS_PASSWORD
  sqlcl_session "$1" "$LOCAL_SYS_PASSWORD" "$LOCAL_HOST:1521/$LOCAL_SERVICE"
}

require_prod_target() {
  if [[ -z "${PROD_CONNECT:-}" && -z "${PROD_TNS:-}" ]]; then
    die "set PROD_CONNECT (host:port/service) or PROD_TNS + TNS_ADMIN"
  fi
  if [[ -n "${PROD_TNS:-}" && ! -f "${TNS_ADMIN:-}/tnsnames.ora" ]]; then
    die "PROD_TNS needs TNS_ADMIN pointing at a folder that contains tnsnames.ora"
  fi
  check_password PROD_PASSWORD
}

prod_conn_string() {
  if [[ -n "${PROD_TNS:-}" ]]; then echo "$PROD_TNS"; else echo "$PROD_CONNECT"; fi
}

prod_link_using() {
  if [[ -n "${PROD_TNS:-}" ]]; then
    tns_descriptor "$PROD_TNS" "$TNS_ADMIN/tnsnames.ora" || die "alias $PROD_TNS not found in $TNS_ADMIN/tnsnames.ora"
  else
    echo "$PROD_CONNECT"
  fi
}

sqlcl_prod() {
  sqlcl_session "$PROD_USER" "$PROD_PASSWORD" "$(prod_conn_string)"
}

# Destructive local operations (DROP USER ...) may only ever reach the
# oracle-local container started by this repo, never a real database that
# LOCAL_HOST was pointed at by mistake.
assert_local_container() {
  local svc
  svc="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$LOCAL_HOST" 2>/dev/null || true)"
  if [[ "$svc" != oracle-local ]]; then
    die "refusing to modify $LOCAL_HOST: it is not the oracle-local container of this repo (check LOCAL_HOST)"
  fi
}

# Drop and recreate a schema in the LOCAL database (never prod).
recreate_local_schema() {
  local schema out
  schema="$(upper "$1")"
  validate_identifier "$schema" schema
  assert_local_container
  out="$(sqlcl_local system <<SQL
begin
  for s in (select sid, serial# as serial from v\$session where username = '$schema') loop
    execute immediate 'alter system kill session ''' || s.sid || ',' || s.serial || ''' immediate';
  end loop;
end;
/
declare
  n number;
begin
  select count(*) into n from dba_users where username = '$schema';
  if n > 0 then
    execute immediate 'drop user $schema cascade';
  end if;
end;
/
create user $schema identified by "$LOCAL_SYS_PASSWORD" default tablespace users quota unlimited on users;
grant connect, resource, create view, create synonym, create materialized view, create database link to $schema;
set heading off feedback off pagesize 0
prompt __BEGIN__
select 'USER_OK' from dba_users where username = '$schema';
prompt __END__
SQL
)" || die "cannot connect to the local DB as SYSTEM (is it up? run: make up)" 2
  if ! printf '%s\n' "$out" | between_markers | grep USER_OK >/dev/null; then
    printf '%s\n' "$out" | redact_secrets >&2
    die "could not recreate local schema $schema"
  fi
}

# Tidy DBMS_METADATA output: strip trailing blanks and leading blank lines,
# reset sequence START WITH values (stable diffs), and drop the Data Pump
# load statements (INSERT ... @ KU$) that GET_DDL appends to tables created
# by a network import.
clean_ddl() {
  sed -E -e 's/[[:space:]]+$//' -e 's/START WITH [0-9]+/START WITH 1/' | awk '
    skip { if ($0 ~ /@ KU\$;$/) skip = 0; next }
    /^[[:blank:]]*INSERT \/\*\+[[:blank:]]+APPEND[[:blank:]]+NESTED_TABLE_SET_REFS/ { if ($0 !~ /@ KU\$;$/) skip = 1; next }
    NF { seen = 1 }
    seen'
}

# A source file must hold exactly one CREATE OR REPLACE PACKAGE [BODY] /
# FUNCTION / PROCEDURE unit named after the file (deploy runs the whole file on prod). Prints the
# problem and returns 1 when it does not.
validate_source_file() {
  local file="$1" base name ext want norm head upper_name name_re re slashes
  local re_name='^[a-z][a-z0-9_$#]*$'
  base="$(basename "$file")"
  ext="${base##*.}"
  name="${base%.*}"
  case "$ext" in
    pks) want="PACKAGE" ;;
    pkb) want="PACKAGE BODY" ;;
    fnc) want="FUNCTION" ;;
    prc) want="PROCEDURE" ;;
    *) echo "$file: expected a .pks, .pkb, .fnc or .prc file" >&2; return 1 ;;
  esac
  if [[ "$name" != "$(lower "$name")" ]]; then
    echo "$file: file names must be lower case" >&2
    return 1
  fi
  if [[ ! "$name" =~ $re_name ]]; then
    echo "$file: invalid package file name" >&2
    return 1
  fi
  norm="$(normalize_source < "$file")"
  head="$(printf '%s\n' "$norm" | head -n 1 | tr '[:lower:]' '[:upper:]')"
  upper_name="$(upper "$name")"
  name_re="${upper_name//\$/\\\$}"
  re="^CREATE OR REPLACE ${want} (\"?[A-Z0-9_\$#]+\"?\\.)?\"?${name_re}\"?([[:blank:]]|\\(|\$)"
  if [[ ! "$head" =~ $re ]]; then
    echo "$file: must start with CREATE OR REPLACE $want $name (only -- comments may come before it)" >&2
    return 1
  fi
  slashes="$(printf '%s\n' "$norm" | grep -c '^/$' || true)"
  if [[ "$slashes" != 1 ]]; then
    echo "$file: only one unit allowed (a single / line, at the end)" >&2
    return 1
  fi
}

# Absolute path of the data scope file (DATA_SCOPE, default config/data-scope.conf).
data_scope_file() {
  local f="${DATA_SCOPE:-config/data-scope.conf}"
  case "$f" in /*) ;; *) f="$REPO_ROOT/$f" ;; esac
  [[ -f "$f" ]] || die "data scope file not found: $f"
  echo "$f"
}

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------
# SQLcl echoes a failing statement (e.g. CREATE DATABASE LINK ... IDENTIFIED BY
# "<password>"). Pipe diagnostic output through this before printing it.
# Never use it on data (package source), where it could rewrite real text.
redact_secrets() {
  local text v
  text="$(cat)"
  for v in "${PROD_PASSWORD:-}" "${LOCAL_SYS_PASSWORD:-}"; do
    if [[ -n "$v" ]]; then text="${text//"$v"/***}"; fi
  done
  printf '%s\n' "$text"
}

# Passwords go inside double quotes in SQL, so they cannot contain one.
check_password() {
  local v="${!1:-}"
  if [[ -z "$v" ]]; then die "missing config: $1 (set it in .env or the environment)"; fi
  case "$v" in
    *\"*) die "$1 must not contain a double quote (\")" ;;
  esac
}

# fetch_prod_sources DIR [NAME...]: write the normalized source of every package,
# standalone function and procedure of APP_SCHEMA (or only the NAMEs) to
# DIR/<name>.pks|.pkb|.fnc|.prc, using one query in one SQLcl session.
# Returns 2 when prod cannot be read.
fetch_prod_sources() {
  local dir="$1" schema filter="" n out f
  shift
  schema="$(upper "$APP_SCHEMA")"
  if (($# > 0)); then
    for n in "$@"; do filter="$filter,'$(upper "$n")'"; done
    filter="and name in (${filter#,})"
  fi
  out="$(sqlcl_prod <<SQL
set heading off feedback off pagesize 0 linesize 32767 trimout on
prompt __BEGIN__
select name || chr(9) || type || chr(9) || '|' || rtrim(rtrim(text, chr(10)), chr(13))
  from all_source
 where owner = '$schema' and type in ('PACKAGE', 'PACKAGE BODY', 'FUNCTION', 'PROCEDURE') $filter
 order by name, type, line;
prompt __END__
SQL
)" || return 2
  # Rows are NAME<tab>TYPE<tab>|text; the "|" keeps blank lines (SQLcl drops NULL rows).
  printf '%s\n' "$out" | between_markers | awk -v dir="$dir" '
    {
      i = index($0, "\t"); if (!i) next
      name = substr($0, 1, i - 1); rest = substr($0, i + 1)
      j = index(rest, "\t"); if (!j) next
      type = substr(rest, 1, j - 1); text = substr(rest, j + 1)
      sub(/^\|/, "", text)
      ext = (type == "PACKAGE BODY") ? ".pkb" : (type == "FUNCTION") ? ".fnc" : (type == "PROCEDURE") ? ".prc" : ".pks"
      f = dir "/" tolower(name) ext ".raw"
      if (f != prev) { if (prev != "") close(prev); prev = f }
      print text > f
    }' || return 2
  for f in "$dir"/*.raw; do
    if [[ -f "$f" ]]; then
      normalize_source < "$f" > "${f%.raw}"
      rm -f "$f"
    fi
  done
}

# ---------------------------------------------------------------------------
# Docker memory (each Oracle container needs about 2 GB)
# ---------------------------------------------------------------------------
# Sum "used / limit" lines from `docker stats --format '{{.MemUsage}}'`, in MiB.
sum_mem_usage_mb() {
  awk '
    function mb(v,   n, u) {
      n = v + 0; u = v; sub(/^[0-9.]+/, "", u)
      if (u == "KiB") return n / 1024
      if (u == "MiB") return n
      if (u == "GiB") return n * 1024
      if (u == "kB") return n * 1000 / 1048576
      if (u == "MB") return n * 1000000 / 1048576
      if (u == "GB") return n * 1000000000 / 1048576
      return n / 1048576
    }
    NF { total += mb($1) }
    END { printf "%d\n", total + 0.5 }'
}

docker_free_mb() {
  local total used
  total="$(docker info --format '{{.MemTotal}}')"
  used="$(docker stats --no-stream --format '{{.MemUsage}}' | sum_mem_usage_mb)"
  echo $((total / 1048576 - used))
}

# warn_low_memory NEED_MB WHAT: warn (and return 1) when Docker has less free memory.
warn_low_memory() {
  local free
  free="$(docker_free_mb 2>/dev/null)" || return 0
  if ((free < $1)); then
    echo "warning: Docker has about ${free} MB of free memory; $2 needs about $1 MB." >&2
    echo "  Stop other databases (make down) or give Docker more RAM" >&2
    echo "  (Docker Desktop > Settings > Resources), otherwise containers may be killed." >&2
    docker stats --no-stream --format '  running: {{.Name}} {{.MemUsage}}' >&2
    return 1
  fi
}

# True when the scope file has a "USED <rule>" line.
scope_uses_used() {
  awk 'toupper($1) == "USED" { found = 1 } END { exit found ? 0 : 1 }' "$1"
}

# expand_used_scope SCOPE USED_TABLES: replace the "USED <rule>" line with one
# "<TABLE> <rule>" line per used table (one name per line in USED_TABLES)
# that has no rule of its own.
expand_used_scope() {
  awk '
    FILENAME == ARGV[1] { if (NF) used[++n] = toupper($1); next }
    { line = $0; sub(/\r$/, "", line) }
    toupper($1) == "USED" {
      rule = line; sub(/^[[:blank:]]*[A-Za-z]+[[:blank:]]+/, "", rule)
      if (toupper(rule) !~ /^WHERE/) sub(/[[:blank:]]*#.*$/, "", rule)
      next
    }
    { print line; if (line !~ /^[[:blank:]]*(#|$)/) explicit[toupper($1)] = 1 }
    END {
      if (rule == "") exit
      for (i = 1; i <= n; i++) if (!(used[i] in explicit)) print used[i] " " rule
    }' "$2" "$1"
}

# scope_plan SCOPE < "TABLE|NUM_ROWS" lines: TABLE<tab>RULE<tab>PROD_ROWS<tab>EST_ROWS
# per table, then a TOTAL line. Unknown counts print as "?".
scope_plan() {
  awk -v scope="$1" '
    BEGIN {
      dflt = "FULL"
      while ((getline line < scope) > 0) {
        sub(/\r$/, "", line)
        if (line ~ /^[[:blank:]]*(#|$)/) continue
        sub(/^[[:blank:]]+/, "", line)
        t = line; sub(/[[:blank:]].*$/, "", t)
        rest = substr(line, length(t) + 1); sub(/^[[:blank:]]+/, "", rest)
        k = rest; sub(/[[:blank:]].*$/, "", k)
        if (toupper(k) != "WHERE") sub(/[[:blank:]]*#.*$/, "", rest)
        rest = toupper(k) substr(rest, length(k) + 1)
        if (toupper(t) == "DEFAULT") dflt = rest; else rules[toupper(t)] = rest
      }
    }
    {
      i = index($0, "|"); t = substr($0, 1, i - 1); n = substr($0, i + 1)
      rule = (t in rules) ? rules[t] : dflt
      split(rule, p, /[[:blank:]]+/)
      known = (n ~ /^[0-9]+$/)
      if (p[1] == "NONE") est = 0
      else if (!known || p[1] == "WHERE") est = "?"
      else if (p[1] == "FULL") est = n
      else if (p[1] == "LIMIT") est = (n + 0 < p[2] + 0) ? n : p[2]
      else if (p[1] == "SAMPLE") est = int(n * p[2] / 100)
      else est = "?"
      if (known) prod += n
      if (est != "?") total += est
      printf "%s\t%s\t%s\t%s\n", t, rule, known ? n : "?", est
    }
    END { printf "TOTAL\t\t%d\t%d\n", prod, total }'
}

# Tables of APP_SCHEMA that the packages use, directly or through views,
# functions, procedures and other packages (ALL_DEPENDENCIES on prod).
# Tables reached only through dynamic SQL cannot be found this way.
prod_used_tables() {
  local schema out
  schema="$(upper "$APP_SCHEMA")"
  out="$(sqlcl_prod <<SQL
set heading off feedback off pagesize 0 linesize 4000
prompt __BEGIN__
select distinct referenced_name from (
  select name, type, referenced_name, referenced_type from all_dependencies
   where owner = '$schema' and referenced_owner = '$schema')
 where referenced_type = 'TABLE'
 start with type in ('PACKAGE', 'PACKAGE BODY', 'FUNCTION', 'PROCEDURE')
 connect by nocycle prior referenced_name = name
 order by 1;
prompt __END__
SQL
)" || return 2
  printf '%s\n' "$out" | between_markers | tr -d ' \t' | grep -v '^$' || true
}

# Connection details of the local database, ready to paste into a client.
local_conn_info() {
  local user host="localhost" port="$LOCAL_PORT" svc="$LOCAL_SERVICE"
  user="$(upper "$APP_SCHEMA")"
  cat <<EOF2
Local database (a copy of prod data, reachable from this machine only)
  Host        $host
  Port        $port
  Service     $svc   (choose "Service name", not SID)
  User        $user   (admin: SYSTEM, same password)
  Password    $LOCAL_SYS_PASSWORD

DBeaver / SQL Developer / DataGrip (JDBC URL)
  jdbc:oracle:thin:@//$host:$port/$svc

PL/SQL Developer / Toad / SQL*Plus (EZConnect, paste into "Database")
  $host:$port/$svc
  $user/"$LOCAL_SYS_PASSWORD"@//$host:$port/$svc

tnsnames.ora entry (for tools that need a TNS alias)
  PLSQL_LOCAL =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = $host)(PORT = $port))
      (CONNECT_DATA = (SERVICE_NAME = $svc)))
EOF2
}

# ---------------------------------------------------------------------------
# make check helpers
# ---------------------------------------------------------------------------
# Read a SQLcl connection error on stdin; print what to fix in .env.
explain_connect_error() {
  local text
  text="$(cat)"
  case "$text" in
    *ORA-01017*) echo "wrong user name or password: check PROD_USER and PROD_PASSWORD in .env" ;;
    *ORA-12514* | *ORA-12505*) echo "the database does not know this service name: check the part after / in PROD_CONNECT (a service name, not a SID)" ;;
    *ORA-17868* | *"Unknown host"* | *"Name or service not known"*) echo "unknown host name: check the host in PROD_CONNECT, and your VPN or DNS" ;;
    *ORA-12541* | *ORA-12170* | *ORA-17002* | *"Network Adapter"* | *"timed out"*) echo "nothing answers at that address: check host and port in PROD_CONNECT, the VPN and firewalls" ;;
    *ORA-28000*) echo "the account is locked: ask your DBA to unlock PROD_USER" ;;
    *ORA-28001*) echo "the password has expired: change it, then update PROD_PASSWORD" ;;
    *) echo "unexpected error: see the error above" ;;
  esac
}

# Sanity-check an EZConnect string (host[:port]/service). Prints the problem
# and returns 1; full descriptors "(DESCRIPTION=...)" are accepted as is.
check_connect_target() {
  local c="$1" host re='^[^:/[:space:]]+(:[0-9]+)?/[^/[:space:]]+$'
  case "$c" in \(*) return 0 ;; esac
  if [[ ! "$c" =~ $re ]]; then
    echo "PROD_CONNECT must look like host:port/service (got '$c')"
    return 1
  fi
  host="${c%%[:/]*}"
  case "$host" in
    localhost | 127.0.0.1 | 0.0.0.0)
      echo "PROD_CONNECT uses $host, but the tool connects from inside Docker, where $host is the container itself; for a database on this machine use host.docker.internal"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Partial sync (make sync ONLY="a b")
# ---------------------------------------------------------------------------
# The given tables of APP_SCHEMA on prod plus every table their foreign keys
# lead to (parents, grandparents...), one per line.
prod_tables_with_parents() {
  local schema list="" t out
  schema="$(upper "$APP_SCHEMA")"
  for t in "$@"; do list="$list,'$(upper "$t")'"; done
  list="${list#,}"
  out="$(sqlcl_prod <<SQL
set heading off feedback off pagesize 0 linesize 4000
prompt __BEGIN__
with fk as (
  select c.table_name child, p.table_name parent
    from all_constraints c
    join all_constraints p on p.owner = c.r_owner and p.constraint_name = c.r_constraint_name
   where c.owner = '$schema' and c.constraint_type = 'R' and p.owner = '$schema')
select table_name from all_tables where owner = '$schema' and table_name in ($list)
union
select parent from fk start with child in ($list) connect by nocycle prior parent = child;
prompt __END__
SQL
)" || return 2
  printf '%s\n' "$out" | between_markers | tr -d ' \t' | grep -v '^$' || true
}

# "and <column> in ('A','B')" when ONLY_TABLES (comma separated) is set.
only_filter() {
  if [[ -n "${ONLY_TABLES:-}" ]]; then
    printf "and %s in (%s)" "$1" "$(printf '%s' "$ONLY_TABLES" | sed "s/[^,][^,]*/'&'/g")"
  fi
}

# ---------------------------------------------------------------------------
# Source files: packages, standalone functions and procedures
# ---------------------------------------------------------------------------
# source_path NAME TYPE -> path of its file (name in lower case)
source_path() {
  case "$2" in
    PACKAGE) echo "src/packages/$1.pks" ;;
    "PACKAGE BODY") echo "src/packages/$1.pkb" ;;
    FUNCTION) echo "src/functions/$1.fnc" ;;
    PROCEDURE) echo "src/procedures/$1.prc" ;;
  esac
}

# source_name PATH -> object name (lower case)
source_name() {
  local b
  b="$(basename "$1")"
  echo "${b%.*}"
}

# All source files in the repository (relative paths), one per line.
source_files() {
  local f
  for f in "$REPO_ROOT"/src/packages/*.pks "$REPO_ROOT"/src/packages/*.pkb \
    "$REPO_ROOT"/src/functions/*.fnc "$REPO_ROOT"/src/procedures/*.prc; do
    if [[ -f "$f" ]]; then echo "${f#"$REPO_ROOT"/}"; fi
  done
}

# The existing files of one object name (any type), one per line.
object_files() {
  local t f
  while IFS= read -r t; do
    f="$(source_path "$1" "$t")"
    if [[ -f "$REPO_ROOT/$f" ]]; then echo "$f"; fi
  done <<EOF2
PACKAGE
PACKAGE BODY
FUNCTION
PROCEDURE
EOF2
}
