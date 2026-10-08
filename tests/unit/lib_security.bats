#!/usr/bin/env bats

setup() {
  load test_helper
  setup_lib
}

@test "redact_secrets hides the prod and local passwords in SQLcl output" {
  export PROD_PASSWORD='Pr0d$ecret' LOCAL_SYS_PASSWORD='l0cal&pw'
  run redact_secrets <<'EOF2'
create database link X connect to app identified by "Pr0d$ecret" using 'h:1/s' bad
conn system/"l0cal&pw"@oracle-local:1521/FREEPDB1
ORA-00933: SQL command not properly ended
EOF2
  [ "$status" -eq 0 ]
  [[ "$output" != *'Pr0d$ecret'* ]] || false
  [[ "$output" != *'l0cal&pw'* ]] || false
  [[ "$output" == *'identified by "***"'* ]] || false
  [[ "$output" == *"ORA-00933"* ]] || false
}

@test "redact_secrets passes text through when no password is set" {
  unset PROD_PASSWORD LOCAL_SYS_PASSWORD
  run redact_secrets <<< "hello"
  [ "$output" = "hello" ]
}

@test "check_password rejects double quotes and empty values" {
  export P1='ok pass#1' P2='bad"pass' P3=''
  run check_password P1
  [ "$status" -eq 0 ]
  run check_password P2
  [ "$status" -eq 1 ]
  [[ "$output" == *'P2 must not contain a double quote'* ]] || false
  run check_password P3
  [ "$status" -eq 1 ]
}
