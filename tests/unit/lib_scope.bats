#!/usr/bin/env bats

setup() {
  load test_helper
  setup_lib
}

scope() {
  printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/scope.conf"
  run scope_to_plsql "$BATS_TEST_TMPDIR/scope.conf" APP
}

@test "DEFAULT FULL emits nothing; comments and blank lines are ignored" {
  scope "# header" "" "DEFAULT   FULL   # everything"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "table rules become table-level filters with upper-case names" {
  scope "orders SAMPLE 5" "audit_trail NONE" "customers FULL"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "  DBMS_DATAPUMP.DATA_FILTER(h, 'SUBQUERY', 'WHERE ORA_HASH(ROWID, 99) < 5', 'ORDERS', 'APP');" ]
  [ "${lines[1]}" = "  DBMS_DATAPUMP.DATA_FILTER(h, 'INCLUDE_ROWS', 0, 'AUDIT_TRAIL', 'APP');" ]
  [ "${lines[2]}" = "  DBMS_DATAPUMP.DATA_FILTER(h, 'SUBQUERY', 'WHERE 1=1', 'CUSTOMERS', 'APP');" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "WHERE keeps the rest of the line and doubles single quotes" {
  scope "ORDER_LOGS  WHERE status = 'X' and created_at >= add_months(sysdate, -3)"
  [ "${lines[0]}" = "  DBMS_DATAPUMP.DATA_FILTER(h, 'SUBQUERY', 'WHERE status = ''X'' and created_at >= add_months(sysdate, -3)', 'ORDER_LOGS', 'APP');" ]
}

@test "DEFAULT rules are job-wide" {
  # Data Pump rejects a job-level INCLUDE_ROWS 0 next to table-level filters
  # (ORA-39001), so "no rows" is a job-level subquery that matches nothing.
  scope "DEFAULT NONE"
  [ "$output" = "  DBMS_DATAPUMP.DATA_FILTER(h, 'SUBQUERY', 'WHERE 1=0');" ]
  scope "default sample 10"
  [ "$output" = "  DBMS_DATAPUMP.DATA_FILTER(h, 'SUBQUERY', 'WHERE ORA_HASH(ROWID, 99) < 10');" ]
}

@test "CRLF files work" {
  printf 'ORDERS NONE\r\n' > "$BATS_TEST_TMPDIR/scope.conf"
  run scope_to_plsql "$BATS_TEST_TMPDIR/scope.conf" APP
  [ "$output" = "  DBMS_DATAPUMP.DATA_FILTER(h, 'INCLUDE_ROWS', 0, 'ORDERS', 'APP');" ]
}

@test "bad SAMPLE values are rejected with the line number" {
  scope "# c" "ORDERS SAMPLE 0"
  [ "$status" -eq 2 ]
  [[ "$output" == *"data-scope: line 2: SAMPLE needs a percentage 1-99 for ORDERS"* ]] || false
  scope "ORDERS SAMPLE abc"
  [ "$status" -eq 2 ]
}

@test "unknown rules, empty WHERE and bad table names are rejected" {
  scope "ORDERS HALF"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown rule HALF"* ]] || false
  scope "ORDERS WHERE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"WHERE needs a condition"* ]] || false
  scope "bad;name FULL"
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid table name"* ]] || false
}
