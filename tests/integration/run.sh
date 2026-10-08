#!/usr/bin/env bash
# End-to-end test of the workflow against a throwaway fake prod (spec section 8).
# Uses its own containers/network/ports, so it never touches your dev DB.
# Needs Docker and rsync. KEEP=1 keeps the containers and work dir for debugging.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"

export COMPOSE_PROJECT=plsqltest DOCKER_NETWORK=plsqltest
export LOCAL_HOST=plsqltest-local FAKEPROD_HOST=plsqltest-fakeprod
export LOCAL_PORT=1540 FAKEPROD_PORT=1541
export FAKEPROD_IMAGE="${FAKEPROD_IMAGE:-gvenzl/oracle-free:23-slim-faststart}"
export FAKEPROD_PDB="${FAKEPROD_PDB:-FREEPDB1}"
export ORACLE_VERSION="${ORACLE_VERSION:-23}" LOCAL_IMAGE_SUFFIX=-faststart

passed=0
ok() { passed=$((passed + 1)); echo "  ok - $1"; }
fail() { echo "  FAIL - $1" >&2; exit 1; }

cleanup() {
  if [[ "${KEEP:-0}" == 1 ]]; then
    echo "kept work dir: $WORK"
    return
  fi
  if [[ -d "$WORK/repo" ]]; then
    (cd "$WORK/repo" && fakeprod_compose rm -sfv oracle-fakeprod >/dev/null 2>&1; scripts/local.sh reset >/dev/null 2>&1) || true
  fi
  docker network rm "$DOCKER_NETWORK" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fakeprod_compose() {
  docker compose -p "$COMPOSE_PROJECT" -f tests/integration/fakeprod-compose.yml "$@"
}

# q prod|local "select ..." -> single value, whitespace removed
q() {
  local query
  query="$(printf 'set heading off feedback off pagesize 0\nprompt __BEGIN__\n%s;\nprompt __END__\n' "$2")"
  if [[ "$1" == prod ]]; then
    printf '%s\n' "$query" | sqlcl_prod | between_markers | tr -d '[:space:]'
  else
    printf '%s\n' "$query" | sqlcl_local APP | between_markers | tr -d '[:space:]'
  fi
}

setup_repo() {
  echo "# setting up scratch repo in $WORK/repo"
  mkdir -p "$WORK/repo"
  rsync -a --exclude .git --exclude .env "$ROOT/" "$WORK/repo/"
  cd "$WORK/repo"
  rm -f src/packages/*.pks src/packages/*.pkb ci/schema/*.sql
  cat > .env <<EOF
PROD_CONNECT=$FAKEPROD_HOST:1521/$FAKEPROD_PDB
PROD_USER=APP
PROD_PASSWORD=app
APP_SCHEMA=APP
LOCAL_SYS_PASSWORD=local_pw1
DATA_SCOPE=tests/integration/data-scope.test.conf
EOF
  git init -q -b main
  git config user.email test@example.com
  git config user.name test
  git add -A
  git commit -q -m baseline
  # shellcheck source=scripts/lib.sh
  source scripts/lib.sh
  load_env
  resolve_settings
}

start_containers() {
  if ! warn_low_memory 4000 "the integration test (two extra Oracle databases)"; then
    fail "not enough free Docker memory; stop other databases first"
  fi
  echo "# starting fake prod ($FAKEPROD_IMAGE) and local DB ($ORACLE_VERSION)"
  ensure_network
  ensure_sqlcl_image
  fakeprod_compose up -d --wait --wait-timeout 1200 oracle-fakeprod
  scripts/local.sh up
  local _ seeded=""
  local done_sql="select count(*) from user_objects where object_name = 'PKG_CUSTOMER' and object_type = 'PACKAGE BODY'"
  for _ in $(seq 1 90); do
    seeded="$(q prod "$done_sql" 2>/dev/null || true)"
    if [[ "$seeded" == 1 ]]; then break; fi
    sleep 10
  done
  if [[ "$seeded" == 1 ]]; then ok "fake prod is seeded"; else fail "fake prod seed did not finish"; fi
  if [[ "$(q prod 'select count(*) from customers')" == 5000 ]]; then ok "sqlcl_prod works"; else fail "sqlcl_prod"; fi
  recreate_local_schema APP
  local sga mem
  sga="$(printf "set heading off feedback off pagesize 0\nselect display_value from v\$parameter where name = 'sga_target';\n" \
    | docker exec -i "$LOCAL_HOST" sqlplus -s / as sysdba | tr -d '[:space:]')"
  mem="$(docker stats --no-stream --format '{{.MemUsage}}' "$LOCAL_HOST" | sum_mem_usage_mb)"
  if [[ "$sga" == 768M ]] && ((mem < 1600)); then ok "local DB memory is limited (SGA $sga, ${mem} MB used)"; else fail "local DB memory: SGA $sga, ${mem} MB"; fi
  if [[ "$(q local 'select count(*) from user_tables')" == 0 ]]; then ok "recreate_local_schema + sqlcl_local work"; else fail "local schema"; fi
}

test_sync() {
  echo "# make sync"
  if ! make sync >"$WORK/sync.log" 2>&1; then cat "$WORK/sync.log"; fail "make sync"; fi
  ok "make sync finished"
  if [[ "$(q local 'select count(*) from customers')" == 5000 ]]; then ok "CUSTOMERS FULL = 5000 rows"; else fail "customers"; fi
  if [[ "$(q local 'select count(*) from orders')" == 3000 ]]; then ok "ORDERS WHERE = 3000 rows"; else fail "orders"; fi
  if [[ "$(q local 'select count(*) from audit_trail')" == 0 ]]; then ok "AUDIT_TRAIL NONE = 0 rows"; else fail "audit_trail"; fi
  local events
  events="$(q local 'select count(*) from events')"
  if ((events >= 600 && events <= 1400)); then ok "EVENTS SAMPLE 10 = $events rows"; else fail "events sample: $events"; fi
  if [[ "$(q local "select status from user_objects where object_name = 'PKG_CUSTOMER' and object_type = 'PACKAGE BODY'")" == VALID ]]; then
    ok "package imported and VALID locally"
  else fail "pkg_customer locally"; fi
  if [[ "$(q local 'select count(*) from user_db_links')" == 0 ]]; then ok "sync link removed"; else fail "db link left behind"; fi
  if grep -q '"CUSTOMERS"' ci/schema/03_tables.sql && grep -q '"ACTIVE_CUSTOMERS"' ci/schema/05_views.sql; then
    ok "ci/schema exported"
  else fail "ci/schema content"; fi
  if grep -qi 'START WITH 1 ' ci/schema/01_sequences.sql || grep -qi 'START WITH 1$' ci/schema/01_sequences.sql; then
    ok "sequence start values normalized"
  else fail "sequence normalization"; fi
  if ! grep -q 'KU\$' ci/schema/*.sql; then ok "no Data Pump load statements in ci/schema"; else fail "KU\$ statements in ci/schema"; fi
}

PKS=src/packages/pkg_customer.pks
PKB=src/packages/pkg_customer.pkb

# Recompile the prod package body with an extra comment line (a "manual hotfix").
prod_hotfix() {
  awk -v c="-- $1" '/^END pkg_customer;$/ { print c } { print }' "$PKB" | sqlcl_prod >/dev/null
}

ends_with_one_slash() {
  [[ "$(tail -n 1 "$1")" == "/" && "$(tail -n 2 "$1" | head -n 1)" != "/" ]]
}

test_pull() {
  echo "# make pull"
  make pull PKG=pkg_customer >/dev/null || fail "make pull"
  if [[ "$(git log -1 --format=%s)" == "sync(prod): add pkg_customer" ]]; then ok "pull commits a new package"; else fail "pull commit message"; fi
  if ends_with_one_slash "$PKS" && ends_with_one_slash "$PKB"; then ok "files end with exactly one /"; else fail "trailing slash"; fi
  if head -n 1 "$PKB" | grep -q '^CREATE OR REPLACE PACKAGE BODY pkg_customer AS$'; then ok "header normalized"; else fail "header"; fi
  if grep -q '^$' "$PKB"; then ok "blank lines inside the body survive"; else fail "blank lines lost"; fi

  local before
  before="$(git rev-parse HEAD)"
  make pull PKG=PKG_Customer >/dev/null || fail "second pull"
  if [[ "$(git rev-parse HEAD)" == "$before" ]]; then ok "re-pull without changes makes no commit"; else fail "re-pull committed"; fi

  echo "-- local edit" >> "$PKB"
  if make pull PKG=pkg_customer >"$WORK/pull.log" 2>&1; then fail "pull overwrote uncommitted work"; fi
  if grep -q 'uncommitted changes' "$WORK/pull.log" && tail -n 1 "$PKB" | grep -q 'local edit'; then ok "pull refuses to overwrite uncommitted edits"; else fail "uncommitted guard"; fi
  git checkout -- "$PKB"

  prod_hotfix "hotfix on prod 1"
  echo "unrelated" > unrelated.txt
  git add unrelated.txt
  make pull PKG=pkg_customer >/dev/null || fail "pull after hotfix"
  if [[ "$(git log -1 --format=%s)" == "sync(prod): pkg_customer drift from prod" ]] && grep -q 'hotfix on prod 1' "$PKB"; then
    ok "pull commits a prod hotfix as drift"
  else fail "drift commit"; fi
  if git diff --cached --name-only | grep -q '^unrelated.txt$' && ! git show --name-only --format= HEAD | grep -q unrelated.txt; then
    ok "other staged files are not swept into the sync commit"
  else fail "staged file leaked into sync commit"; fi
  git reset -q unrelated.txt && rm -f unrelated.txt

  if make pull PKG=no_such_pkg >"$WORK/pull.log" 2>&1; then fail "unknown package pulled"; fi
  if grep -q 'not found' "$WORK/pull.log"; then ok "unknown package is reported"; else fail "unknown package message"; fi
  if make pull PKG="x;drop" >"$WORK/pull.log" 2>&1; then fail "bad name accepted"; fi
  if grep -q "invalid name" "$WORK/pull.log"; then ok "bad package name rejected"; else fail "bad name message"; fi

  echo "drop package body pkg_customer;" | sqlcl_prod >/dev/null
  if make pull PKG=pkg_customer >"$WORK/pull.log" 2>&1; then fail "pull should stop when the body is not visible"; fi
  if grep -q 'body is not visible' "$WORK/pull.log" && git ls-files --error-unmatch "$PKB" >/dev/null 2>&1 && [[ -f "$PKB" ]]; then
    ok "pull keeps the body file when prod shows no body"
  else cat "$WORK/pull.log"; fail "pull deleted or mishandled the body"; fi
  sqlcl_prod < "$PKB" >/dev/null
}

test_compile() {
  echo "# make compile / make sql"
  cp "$PKB" "$WORK/pkb.bak"
  sed 's/RETURN v_customer_name;/RETURN v_customer_name/' "$WORK/pkb.bak" > "$PKB"
  local out
  if out="$(make compile PKG=pkg_customer 2>&1)"; then fail "compile should fail on a syntax error"; fi
  if printf '%s\n' "$out" | grep -Eq '^src/packages/pkg_customer\.pkb:[0-9]+:[0-9]+: PLS-'; then
    ok "compile error reported as file:line:col"
  else printf '%s\n' "$out"; fail "error format"; fi
  cp "$WORK/pkb.bak" "$PKB"
  if make compile PKG=pkg_customer >/dev/null 2>&1; then ok "clean package compiles"; else fail "clean compile"; fi
  { cat "$WORK/pkb.bak"; echo "grant execute on pkg_customer to public;"; } > "$PKB"
  if out="$(make compile PKG=pkg_customer 2>&1)"; then fail "compile should refuse extra statements"; fi
  if printf '%s\n' "$out" | grep -q 'only one unit allowed'; then ok "compile refuses files with extra statements"; else printf '%s\n' "$out"; fail "extra statement message"; fi
  cp "$WORK/pkb.bak" "$PKB"
  if make compile >/dev/null 2>&1; then ok "compile without PKG compiles everything"; else fail "compile all"; fi

  out="$(printf 'select pkg_customer.get_customer_name(1) as name from dual;\n' | scripts/sql.sh)"
  if printf '%s\n' "$out" | grep -q 'Customer 1'; then ok "sql.sh runs stdin against the local DB"; else printf '%s\n' "$out"; fail "sql.sh"; fi
}

test_deploy() {
  echo "# make drift / make deploy"
  if make drift PKG=pkg_customer >/dev/null 2>&1; then ok "drift: prod matches HEAD after pull"; else fail "drift after pull"; fi

  local base out
  if out="$(make deploy BASE=0000000000000000000000000000000000000000 2>&1)" && printf '%s\n' "$out" | grep -q 'nothing to deploy'; then
    ok "all-zero BASE (first push) deploys nothing"
  else printf '%s\n' "$out"; fail "zero base"; fi

  base="$(git rev-parse HEAD)"
  sed "s/RETURN NULL;/RETURN 'UNKNOWN';/" "$PKB" > "$WORK/pkb.new" && cp "$WORK/pkb.new" "$PKB"
  git commit -qam "feat: unknown customer name"
  if ! make deploy BASE="$base" >"$WORK/deploy.log" 2>&1; then cat "$WORK/deploy.log"; fail "deploy"; fi
  if scripts/drift.sh pkg_customer HEAD >/dev/null 2>&1; then ok "deploy: prod source equals main"; else fail "prod != main after deploy"; fi
  if [[ "$(q prod 'select pkg_customer.get_customer_name(-1) from dual')" == UNKNOWN ]]; then ok "deployed code runs on prod"; else fail "deployed behaviour"; fi
  if make deploy BASE="$base" >"$WORK/deploy.log" 2>&1; then ok "re-running the same deploy succeeds"; else cat "$WORK/deploy.log"; fail "re-run deploy"; fi

  base="$(git rev-parse HEAD)"
  { echo "-- Customer API (header comment)"; awk '/^END pkg_customer;$/ { print "    -- v3 spec" } { print }' "$PKS"; } > "$WORK/pks.new"
  cp "$WORK/pks.new" "$PKS"
  awk '/^END pkg_customer;$/ { print "    -- v3 body" } { print }' "$PKB" > "$WORK/pkb.new" && cp "$WORK/pkb.new" "$PKB"
  git commit -qam "feat: v3 with a header comment"
  sqlcl_prod < "$PKS" >/dev/null   # a deploy that died after the spec
  if make deploy BASE="$base" >"$WORK/deploy.log" 2>&1; then ok "re-run after a half-finished deploy (spec at HEAD, body at BASE) succeeds"; else cat "$WORK/deploy.log"; fail "half-finished re-run"; fi
  if make drift PKG=pkg_customer >/dev/null 2>&1; then ok "a header comment does not cause drift"; else make drift PKG=pkg_customer; fail "header comment drift"; fi

  base="$(git rev-parse HEAD)"
  prod_hotfix "hotfix on prod 2"
  sed "s/'UNKNOWN'/'N\/A'/" "$PKB" > "$WORK/pkb.new" && cp "$WORK/pkb.new" "$PKB"
  git commit -qam "feat: n/a customer name"
  if make deploy BASE="$base" >"$WORK/deploy.log" 2>&1; then fail "deploy should abort on drift"; fi
  if grep -q 'deploy aborted' "$WORK/deploy.log"; then ok "deploy aborts on prod drift"; else cat "$WORK/deploy.log"; fail "drift abort message"; fi
  if [[ "$(q prod "select count(*) from user_source where name = 'PKG_CUSTOMER' and text like '%hotfix on prod 2%'")" == 1 ]] \
     && [[ "$(q prod 'select pkg_customer.get_customer_name(-1) from dual')" == UNKNOWN ]]; then
    ok "nothing was compiled on prod after drift"
  else fail "prod changed despite drift"; fi
}

test_ci_schema() {
  echo "# PR check emulation (ci-schema + compile)"
  git checkout -q -- "$PKB"
  if make ci-schema >"$WORK/ci.log" 2>&1; then ok "ci-schema applied"; else cat "$WORK/ci.log"; fail "ci-schema"; fi
  if [[ "$(q local 'select count(*) from customers')" == 0 ]]; then ok "ci-schema has structure only"; else fail "ci-schema has data"; fi
  if make compile >"$WORK/ci.log" 2>&1; then ok "all packages compile against ci/schema"; else cat "$WORK/ci.log"; fail "compile on ci schema"; fi
}

test_sync_copy() {
  echo "# make sync in copy mode (no Data Pump: GET_DDL + INSERT ... SELECT over a link)"
  if ! SYNC_MODE=copy make sync >"$WORK/sync-copy.log" 2>&1; then cat "$WORK/sync-copy.log"; fail "copy-mode sync"; fi
  if grep -q 'copy mode' "$WORK/sync-copy.log"; then ok "copy mode was used"; else cat "$WORK/sync-copy.log"; fail "copy mode not used"; fi
  if [[ "$(q local 'select count(*) from customers')" == 5000 ]]; then ok "copy: CUSTOMERS FULL = 5000 rows"; else fail "copy customers"; fi
  if [[ "$(q local 'select count(*) from orders')" == 3000 ]]; then ok "copy: ORDERS WHERE = 3000 rows"; else fail "copy orders"; fi
  if [[ "$(q local 'select count(*) from audit_trail')" == 0 ]]; then ok "copy: AUDIT_TRAIL NONE = 0 rows"; else fail "copy audit_trail"; fi
  local events
  events="$(q local 'select count(*) from events')"
  if ((events >= 600 && events <= 1400)); then ok "copy: EVENTS SAMPLE 10 = $events rows"; else fail "copy events sample: $events"; fi
  if [[ "$(q local "select status from user_objects where object_name = 'PKG_CUSTOMER' and object_type = 'PACKAGE BODY'")" == VALID ]]; then
    ok "copy: package created and VALID"
  else fail "copy: package"; fi
  if [[ "$(q local "select count(*) from user_constraints where constraint_type = 'R'")" == 1 ]] \
     && [[ "$(q local 'select count(*) from user_views')" == 1 ]] && [[ "$(q local 'select count(*) from user_sequences')" -ge 1 ]]; then
    ok "copy: foreign key, view and sequence created"
  else fail "copy: dependent objects"; fi
  printf "exec pkg_customer.create_customer('NEW00001', 'New customer', 'new@example.com')\ncommit;\n" | scripts/sql.sh >/dev/null
  if [[ "$(q local "select count(*) from customers where customer_code = 'NEW00001' and customer_id > 5000")" == 1 ]]; then
    ok "copy: identity column continues after the copied rows"
  else fail "copy: identity column"; fi
  if [[ "$(printf "set heading off feedback off pagesize 0\nprompt __BEGIN__\nselect count(*) from dba_db_links where db_link like 'PLSQL_SYNC_LINK%%';\nprompt __END__\n" | sqlcl_local system | between_markers | tr -d '[:space:]')" == 0 ]]; then
    ok "copy: sync link removed"
  else fail "copy: db link left behind"; fi
  if grep -q '"CUSTOMERS"' ci/schema/03_tables.sql && ! grep -q 'KU\$' ci/schema/*.sql; then ok "copy: ci/schema exported"; else fail "copy: ci/schema"; fi
}

test_safety() {
  echo "# safety guards"
  if docker port "$LOCAL_HOST" | grep -q '^1521/tcp -> 127\.0\.0\.1:' && ! docker port "$LOCAL_HOST" "$FAKEPROD_HOST" 2>/dev/null | grep -q '0\.0\.0\.0'; then
    ok "databases listen on 127.0.0.1 only"
  else docker port "$LOCAL_HOST"; fail "database ports are exposed beyond localhost"; fi
  if LOCAL_HOST="$FAKEPROD_HOST" scripts/ci_schema.sh >"$WORK/guard.log" 2>&1; then fail "ci_schema dropped a schema on a non-local database"; fi
  if grep -q 'refusing to modify' "$WORK/guard.log" && [[ "$(q prod 'select count(*) from customers')" == 5000 ]]; then
    ok "schema drop refuses any database other than the local container"
  else cat "$WORK/guard.log"; fail "local guard"; fi
}

test_pull_many() {
  echo "# pull many packages at once"
  sqlcl_prod >/dev/null <<'SQL'
begin
  for i in 1 .. 300 loop
    execute immediate 'create or replace package bulk_' || i || ' as function f return number; end;';
    execute immediate 'create or replace package body bulk_' || i || ' as function f return number is begin return ' || i || '; end; end;';
  end loop;
end;
/
SQL
  local before start secs
  before="$(git rev-list --count HEAD)"
  start="$(date +%s)"
  make pull-all >"$WORK/pull-all.log" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if (($(date +%s) - start > 95)); then pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; fail "pull-all still running after 95s"; fi
    sleep 2
  done
  wait "$pid" || { cat "$WORK/pull-all.log"; fail "pull-all"; }
  secs=$(($(date +%s) - start))
  if ((secs <= 90)); then ok "pull-all of 301 packages took ${secs}s"; else fail "pull-all too slow: ${secs}s"; fi
  if [[ "$(git rev-list --count HEAD)" == $((before + 1)) ]] && [[ -f src/packages/bulk_300.pkb ]] \
     && grep -q 'return 300' src/packages/bulk_300.pkb; then
    ok "pull-all makes a single commit"
  else git log --oneline -3; fail "pull-all commit count"; fi
  before="$(git rev-list --count HEAD)"
  make pull-all >/dev/null 2>&1 || fail "second pull-all"
  if [[ "$(git rev-list --count HEAD)" == "$before" ]]; then ok "pull-all without changes makes no commit"; else fail "pull-all re-run committed"; fi
  if make pull PKG="pkg_customer bulk_1" >/dev/null 2>&1; then ok "pull accepts several packages"; else fail "pull with several packages"; fi
  # Clean up so the remaining tests stay fast.
  sqlcl_prod >/dev/null <<'SQL'
begin
  for i in 1 .. 300 loop execute immediate 'drop package bulk_' || i; end loop;
end;
/
SQL
  git rm -q src/packages/bulk_*.pks src/packages/bulk_*.pkb
  git commit -q -m "test: remove bulk packages"
}

test_sync_subset() {
  echo "# sync a subset: LIMIT, USED and parent rows"
  # ORDERS is read directly, CUSTOMERS through the ACTIVE_CUSTOMERS view.
  sqlcl_prod >/dev/null <<'SQL'
create or replace package pkg_report as
  function order_count return number;
  function active_count return number;
end;
/
create or replace package body pkg_report as
  function order_count return number is n number; begin select count(*) into n from orders; return n; end;
  function active_count return number is n number; begin select count(*) into n from active_customers; return n; end;
end;
/
SQL
  printf 'DEFAULT NONE\nORDERS  LIMIT 50\n' > "$WORK/scope-parents.conf"
  local mode customers
  for mode in datapump copy; do
    if ! DATA_SCOPE="$WORK/scope-parents.conf" SYNC_MODE="$mode" make sync >"$WORK/sync-subset.log" 2>&1; then
      cat "$WORK/sync-subset.log"; fail "$mode subset sync"
    fi
    customers="$(q local 'select count(*) from customers')"
    if [[ "$(q local 'select count(*) from orders')" == 50 ]] && ((customers > 0 && customers <= 50)) \
       && [[ "$(q local 'select count(*) from orders o where not exists (select 1 from customers c where c.customer_id = o.customer_id)')" == 0 ]] \
       && [[ "$(q local "select validated from user_constraints where constraint_type = 'R'")" == VALIDATED ]] \
       && [[ "$(q local 'select count(*) from events')" == 0 ]]; then
      ok "$mode: 50 limited orders bring their $customers customers along (foreign key validated)"
    else cat "$WORK/sync-subset.log"; fail "$mode: parent rows"; fi
  done

  printf 'DEFAULT NONE\nUSED    LIMIT 10\n' > "$WORK/scope-used.conf"
  if ! DATA_SCOPE="$WORK/scope-used.conf" make sync >"$WORK/sync-used.log" 2>&1; then cat "$WORK/sync-used.log"; fail "USED sync"; fi
  if [[ "$(q local 'select count(*) from orders')" == 10 ]] && (("$(q local 'select count(*) from customers')" >= 10)) \
     && [[ "$(q local 'select count(*) from events')" == 0 ]] && [[ "$(q local 'select count(*) from audit_trail')" == 0 ]]; then
    ok "USED copies only the tables the packages use (also through views)"
  else cat "$WORK/sync-used.log"; fail "USED tables"; fi

  echo "exec dbms_stats.gather_schema_stats(user)" | sqlcl_prod >/dev/null
  if DATA_SCOPE="$WORK/scope-used.conf" make sync-plan >"$WORK/plan.log" 2>&1 \
     && grep -Eq '^ORDERS +LIMIT 10 +20000 +10' "$WORK/plan.log" && grep -Eq '^EVENTS +NONE +10000 +0' "$WORK/plan.log"; then
    ok "sync-plan shows the rule and expected rows per table"
  else cat "$WORK/plan.log"; fail "sync-plan"; fi
}

test_check_peek() {
  echo "# make check / make peek"
  if make check >"$WORK/check.log" 2>&1 && grep -q 'can reach prod from the local DB' "$WORK/check.log"; then
    ok "make check passes with a correct .env"
  else cat "$WORK/check.log"; fail "make check"; fi
  if PROD_PASSWORD=wrong_pw make check >"$WORK/check.log" 2>&1; then fail "make check should fail with a wrong password"; fi
  if grep -q 'check PROD_USER and PROD_PASSWORD' "$WORK/check.log"; then ok "make check explains a wrong password"; else cat "$WORK/check.log"; fail "wrong password advice"; fi
  if PROD_CONNECT=localhost:1521/FREEPDB1 make check >"$WORK/check.log" 2>&1; then fail "make check should reject localhost"; fi
  if grep -q 'host.docker.internal' "$WORK/check.log"; then ok "make check explains localhost inside Docker"; else cat "$WORK/check.log"; fail "localhost advice"; fi

  if make peek TABLE=customers ROWS=2 >"$WORK/peek.log" 2>&1 && grep -q 'ROWS_ON_PROD' "$WORK/peek.log" && grep -q 5000 "$WORK/peek.log"; then
    ok "make peek shows a prod table"
  else cat "$WORK/peek.log"; fail "make peek"; fi
  if make peek TABLE=customers WHERE="1=1; drop table customers" >"$WORK/peek.log" 2>&1; then fail "peek accepted a second statement"; fi
  if grep -q 'single condition' "$WORK/peek.log" && [[ "$(q prod 'select count(*) from customers')" == 5000 ]]; then
    ok "make peek refuses anything but one condition"
  else cat "$WORK/peek.log"; fail "peek guard"; fi
}

test_sync_only() {
  echo "# make sync ONLY=..."
  local before mode
  before="$(cat ci/schema/*.sql | cksum)"
  for mode in datapump copy; do
    if ! ONLY=orders SYNC_MODE="$mode" make sync >"$WORK/sync-only.log" 2>&1; then cat "$WORK/sync-only.log"; fail "$mode ONLY sync"; fi
    if [[ "$(q local 'select count(*) from user_tables')" == 2 ]] && [[ "$(q local 'select count(*) from orders')" == 3000 ]] \
       && [[ "$(q local "select count(*) from user_objects where object_type like 'PACKAGE%'")" == 0 ]] \
       && [[ "$(q local "select count(*) from user_constraints where constraint_type = 'R'")" == 1 ]]; then
      ok "$mode: ONLY=orders builds ORDERS and its parent CUSTOMERS, nothing else"
    else cat "$WORK/sync-only.log"; fail "$mode: ONLY tables"; fi
  done
  if [[ "$(cat ci/schema/*.sql | cksum)" == "$before" ]]; then ok "partial sync leaves ci/schema unchanged"; else fail "partial sync changed ci/schema"; fi
}

test_routines() {
  echo "# standalone functions and procedures"
  local FNC=src/functions/fn_customer_count.fnc PRC=src/procedures/pr_noop.prc base out
  sqlcl_prod >/dev/null <<'SQL'
create or replace function fn_customer_count return number is
  n number;
begin
  select count(*) into n from customers;
  return n;
end;
/
create or replace procedure pr_noop as
begin
  null;
end;
/
SQL
  make pull PKG="fn_customer_count pr_noop" >/dev/null 2>&1 || fail "pull function/procedure"
  if [[ -f "$FNC" && -f "$PRC" ]] && head -n 1 "$FNC" | grep -q '^CREATE OR REPLACE function fn_customer_count' \
     && [[ -z "$(git status --porcelain -- src/functions src/procedures)" ]]; then
    ok "pull brings functions and procedures into src/functions and src/procedures"
  else ls -R src; fail "pull routines"; fi

  if make compile PKG="fn_customer_count pr_noop" >/dev/null 2>&1 \
     && [[ "$(q local "select count(*) from user_objects where object_name in ('FN_CUSTOMER_COUNT', 'PR_NOOP') and status = 'VALID'")" == 2 ]]; then
    ok "compile builds functions and procedures locally"
  else fail "compile routines"; fi
  cp "$FNC" "$WORK/fnc.bak"
  sed 's/return n;/return n/' "$WORK/fnc.bak" > "$FNC"
  if out="$(make compile PKG=fn_customer_count 2>&1)"; then fail "broken function compiled"; fi
  if printf '%s\n' "$out" | grep -Eq '^src/functions/fn_customer_count\.fnc:[0-9]+:[0-9]+: PLS-'; then
    ok "function compile errors point at the .fnc file"
  else printf '%s\n' "$out"; fail "function error format"; fi
  cp "$WORK/fnc.bak" "$FNC"

  base="$(git rev-parse HEAD)"
  sed 's/return n;/return n + 1000;/' "$WORK/fnc.bak" > "$FNC"
  git commit -qam "feat: count plus 1000"
  if make deploy BASE="$base" >"$WORK/deploy-fn.log" 2>&1 && [[ "$(q prod 'select fn_customer_count from dual')" == 6000 ]]; then
    ok "deploy compiles a changed function on prod"
  else cat "$WORK/deploy-fn.log"; fail "deploy function"; fi

  base="$(git rev-parse HEAD)"
  printf 'create or replace procedure pr_noop as\nbegin\n  null; -- hotfix on prod\nend;\n/\n' | sqlcl_prod >/dev/null
  sed 's/  null;/  null; -- v2/' "$PRC" > "$WORK/prc.new" && cp "$WORK/prc.new" "$PRC"
  git commit -qam "feat: procedure v2"
  if make deploy BASE="$base" >"$WORK/deploy-pr.log" 2>&1; then fail "deploy should abort on procedure drift"; fi
  if grep -q 'deploy aborted' "$WORK/deploy-pr.log" \
     && [[ "$(q prod "select count(*) from user_source where name = 'PR_NOOP' and text like '%hotfix on prod%'")" == 1 ]]; then
    ok "deploy refuses to overwrite a procedure changed on prod"
  else cat "$WORK/deploy-pr.log"; fail "procedure drift"; fi
}

main() {
  setup_repo
  start_containers
  test_sync
  test_sync_copy
  test_check_peek
  test_sync_only
  test_pull
  test_pull_many
  test_compile
  test_deploy
  test_routines
  test_ci_schema
  test_safety
  test_sync_subset
  echo "all $passed checks passed"
}

main "$@"
