#!/usr/bin/env bats
# scope_to_where: data-scope.conf -> PL/SQL lines returning the WHERE clause
# (or NONE) for a table, used by the copy-mode sync.

setup() {
  load test_helper
  setup_lib
}

scope() {
  printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/scope.conf"
  run scope_to_where "$BATS_TEST_TMPDIR/scope.conf"
}

@test "table rules become if lines; DEFAULT becomes the final return" {
  scope "DEFAULT NONE" "orders SAMPLE 5" "customers FULL" "logs WHERE status = 'X'"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "    if p_table = 'ORDERS' then return 'WHERE ORA_HASH(ROWID, 99) < 5'; end if;" ]
  [ "${lines[1]}" = "    if p_table = 'CUSTOMERS' then return ''; end if;" ]
  [ "${lines[2]}" = "    if p_table = 'LOGS' then return 'WHERE status = ''X'''; end if;" ]
  [ "${lines[3]}" = "    return 'NONE';" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "without DEFAULT every other table is copied in full" {
  scope "AUDIT_TRAIL NONE"
  [ "${lines[0]}" = "    if p_table = 'AUDIT_TRAIL' then return 'NONE'; end if;" ]
  [ "${lines[1]}" = "    return '';" ]
}

@test "invalid files are rejected like scope_to_plsql" {
  scope "ORDERS SAMPLE 0"
  [ "$status" -eq 2 ]
  [[ "$output" == *"SAMPLE needs a percentage 1-99"* ]] || false
}
