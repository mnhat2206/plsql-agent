#!/usr/bin/env bats

setup() {
  load test_helper
  setup_lib
  unset FOO BAR SQ PW EMPTY ORACLE_VERSION LOCAL_IMAGE LOCAL_SERVICE LOCAL_IMAGE_SUFFIX DP_VERSION
}

@test "load_env reads values, strips trailing comments and quotes" {
  cat > "$BATS_TEST_TMPDIR/env" <<'EOF'
# a comment

FOO=host:1521/svc     # trailing comment
BAR="pa ss # not a comment"
SQ='single'
PW="p@ss w#rd$&x"
EMPTY=
EOF
  load_env "$BATS_TEST_TMPDIR/env"
  [ "$FOO" = "host:1521/svc" ]
  [ "$BAR" = "pa ss # not a comment" ]
  [ "$SQ" = "single" ]
  [ "$PW" = 'p@ss w#rd$&x' ]
  [ -z "$EMPTY" ]
}

@test "load_env keeps unquoted special characters literally" {
  printf 'PW=abc$def&g@h\n' > "$BATS_TEST_TMPDIR/env"
  load_env "$BATS_TEST_TMPDIR/env"
  [ "$PW" = 'abc$def&g@h' ]
}

@test "load_env does not override variables already set" {
  echo 'FOO=from-file' > "$BATS_TEST_TMPDIR/env"
  export FOO=from-env
  load_env "$BATS_TEST_TMPDIR/env"
  [ "$FOO" = "from-env" ]
}

@test "load_env strips CRLF line endings" {
  printf 'FOO=bar\r\n' > "$BATS_TEST_TMPDIR/env"
  load_env "$BATS_TEST_TMPDIR/env"
  [ "$FOO" = "bar" ]
}

@test "load_env ignores a missing file" {
  run load_env "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 0 ]
}

@test "require_vars names every missing variable" {
  export FOO=x
  run require_vars FOO BAR SQ
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing config: BAR SQ"* ]] || false
}

@test "validate_identifier accepts Oracle names in any case" {
  run validate_identifier pkg_customer
  [ "$status" -eq 0 ]
  run validate_identifier 'PKG$X#1'
  [ "$status" -eq 0 ]
}

@test "validate_identifier rejects anything that could break SQL" {
  for bad in "x;drop" "a'b" "1pkg" "pkg name" "" "a\"b"; do
    run validate_identifier "$bad" package
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid package"* ]] || false
  done
}

@test "upper and lower" {
  [ "$(upper pkg_A)" = "PKG_A" ]
  [ "$(lower PKG_a)" = "pkg_a" ]
}

@test "resolve_settings defaults to 23" {
  resolve_settings
  [ "$LOCAL_IMAGE" = "gvenzl/oracle-free:23-slim" ]
  [ "$LOCAL_SERVICE" = "FREEPDB1" ]
  [ "$DP_VERSION" = "COMPATIBLE" ]
  [ "$DOCKER_NETWORK" = "plsql" ]
  [ "$LOCAL_HOST" = "oracle-local" ]
  [ "$SQLCL_IMAGE" = "plsql-sqlcl:latest" ]
}

@test "resolve_settings maps every supported version" {
  ORACLE_VERSION=19 resolve_settings
  [ "$LOCAL_IMAGE" = "gvenzl/oracle-free:23-slim" ]
  [ "$DP_VERSION" = "19.0.0" ]
  unset LOCAL_IMAGE LOCAL_SERVICE
  ORACLE_VERSION=21 resolve_settings
  [ "$LOCAL_IMAGE" = "gvenzl/oracle-xe:21-slim" ]
  [ "$LOCAL_SERVICE" = "XEPDB1" ]
  [ "$DP_VERSION" = "21.0.0" ]
  unset LOCAL_IMAGE LOCAL_SERVICE
  ORACLE_VERSION=12 resolve_settings
  [ "$LOCAL_IMAGE" = "gvenzl/oracle-xe:21-slim" ]
  [ "$DP_VERSION" = "12.2.0" ]
  unset LOCAL_IMAGE LOCAL_SERVICE
  ORACLE_VERSION=11 resolve_settings
  [ "$LOCAL_IMAGE" = "gvenzl/oracle-xe:18-slim" ]
  [ "$LOCAL_SERVICE" = "XEPDB1" ]
  [ "$DP_VERSION" = "11.2.0" ]
}

@test "resolve_settings appends LOCAL_IMAGE_SUFFIX" {
  LOCAL_IMAGE_SUFFIX=-faststart resolve_settings
  [ "$LOCAL_IMAGE" = "gvenzl/oracle-free:23-slim-faststart" ]
}

@test "resolve_settings keeps an explicit LOCAL_IMAGE and guesses its service" {
  export LOCAL_IMAGE=gvenzl/oracle-xe:21-full
  resolve_settings
  [ "$LOCAL_IMAGE" = "gvenzl/oracle-xe:21-full" ]
  [ "$LOCAL_SERVICE" = "XEPDB1" ]
}

@test "resolve_settings rejects unknown versions" {
  ORACLE_VERSION=99 run resolve_settings
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported ORACLE_VERSION '99'"* ]] || false
}
