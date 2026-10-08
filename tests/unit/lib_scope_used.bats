#!/usr/bin/env bats
# LIMIT rule, USED expansion and the sync plan.

setup() {
  load test_helper
  setup_lib
}

scope_file() { printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/scope.conf"; }

@test "LIMIT keeps at most n rows in both sync modes" {
  scope_file "orders LIMIT 500" "DEFAULT limit 10"
  run scope_to_plsql "$BATS_TEST_TMPDIR/scope.conf" APP
  [ "${lines[0]}" = "  DBMS_DATAPUMP.DATA_FILTER(h, 'SUBQUERY', 'WHERE ROWNUM <= 500', 'ORDERS', 'APP');" ]
  [ "${lines[1]}" = "  DBMS_DATAPUMP.DATA_FILTER(h, 'SUBQUERY', 'WHERE ROWNUM <= 10');" ]
  run scope_to_where "$BATS_TEST_TMPDIR/scope.conf"
  [ "${lines[0]}" = "    if p_table = 'ORDERS' then return 'WHERE ROWNUM <= 500'; end if;" ]
  [ "${lines[1]}" = "    return 'WHERE ROWNUM <= 10';" ]
}

@test "LIMIT needs a positive number" {
  scope_file "ORDERS LIMIT 0"
  run scope_to_plsql "$BATS_TEST_TMPDIR/scope.conf" APP
  [ "$status" -eq 2 ]
  [[ "$output" == *"LIMIT needs a row count"* ]] || false
}

@test "expand_used_scope gives every used table the USED rule unless it has its own" {
  scope_file "DEFAULT NONE" "USED LIMIT 5000   # tables the packages use" "orders WHERE x = 1"
  printf '%s\n' ORDERS CUSTOMERS PRODUCTS > "$BATS_TEST_TMPDIR/used.txt"
  run expand_used_scope "$BATS_TEST_TMPDIR/scope.conf" "$BATS_TEST_TMPDIR/used.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' 'DEFAULT NONE' 'orders WHERE x = 1' 'CUSTOMERS LIMIT 5000' 'PRODUCTS LIMIT 5000')" ]
}

@test "expand_used_scope leaves files without USED unchanged" {
  scope_file "DEFAULT FULL" "AUDIT NONE"
  : > "$BATS_TEST_TMPDIR/used.txt"
  run expand_used_scope "$BATS_TEST_TMPDIR/scope.conf" "$BATS_TEST_TMPDIR/used.txt"
  [ "$output" = "$(printf '%s\n' 'DEFAULT FULL' 'AUDIT NONE')" ]
}

@test "scope_files_uses_used detects a USED line" {
  scope_file "DEFAULT NONE" "  used   LIMIT 10"
  run scope_uses_used "$BATS_TEST_TMPDIR/scope.conf"
  [ "$status" -eq 0 ]
  scope_file "DEFAULT NONE"
  run scope_uses_used "$BATS_TEST_TMPDIR/scope.conf"
  [ "$status" -eq 1 ]
}

@test "scope_plan estimates rows per table from prod statistics" {
  scope_file "DEFAULT NONE" "ORDERS LIMIT 500" "CUSTOMERS FULL" "EVENTS SAMPLE 10" "LOGS WHERE x = 1" "SMALL LIMIT 500"
  run scope_plan "$BATS_TEST_TMPDIR/scope.conf" < <(printf '%s\n' 'AUDIT|1000' 'CUSTOMERS|5000' 'EVENTS|10000' 'LOGS|300' 'ORDERS|20000' 'SMALL|20' 'NOSTATS|')
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'AUDIT\tNONE\t1000\t0')" ]
  [ "${lines[1]}" = "$(printf 'CUSTOMERS\tFULL\t5000\t5000')" ]
  [ "${lines[2]}" = "$(printf 'EVENTS\tSAMPLE 10\t10000\t1000')" ]
  [ "${lines[3]}" = "$(printf 'LOGS\tWHERE x = 1\t300\t?')" ]
  [ "${lines[4]}" = "$(printf 'ORDERS\tLIMIT 500\t20000\t500')" ]
  [ "${lines[5]}" = "$(printf 'SMALL\tLIMIT 500\t20\t20')" ]
  [ "${lines[6]}" = "$(printf 'NOSTATS\tNONE\t?\t0')" ]
  [ "${lines[7]}" = "$(printf 'TOTAL\t\t36320\t6520')" ]
}
