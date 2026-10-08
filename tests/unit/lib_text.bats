#!/usr/bin/env bats

setup() {
  load test_helper
  setup_lib
}

@test "normalize_source turns ALL_SOURCE text into a runnable file" {
  run normalize_source <<'EOF'
PACKAGE pkg AS
  PROCEDURE p;

END pkg;
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'CREATE OR REPLACE PACKAGE pkg AS\n  PROCEDURE p;\n\nEND pkg;\n/')" ]
}

@test "normalize_source replaces any create prefix" {
  run normalize_source <<'EOF'
create or replace editionable package body pkg as
end pkg;
EOF
  [ "${lines[0]}" = "CREATE OR REPLACE package body pkg as" ]
  run normalize_source <<'EOF'
  CREATE   PACKAGE pkg AS
END;
EOF
  [ "${lines[0]}" = "CREATE OR REPLACE PACKAGE pkg AS" ]
}

@test "normalize_source collapses trailing slashes and blank lines to one slash" {
  run normalize_source < <(printf '\n\nPACKAGE p AS\nEND;\n/\n/\n\n  \n')
  [ "$output" = "$(printf 'CREATE OR REPLACE PACKAGE p AS\nEND;\n/')" ]
}

@test "normalize_source strips CR and trailing whitespace" {
  run normalize_source < <(printf 'PACKAGE p AS   \r\n  x;\t\r\nEND;\r\n')
  [ "$output" = "$(printf 'CREATE OR REPLACE PACKAGE p AS\n  x;\nEND;\n/')" ]
}

@test "normalize_source is idempotent" {
  once="$(printf 'PACKAGE p AS\n\n  x;\nEND;\n' | normalize_source)"
  twice="$(printf '%s\n' "$once" | normalize_source)"
  [ "$once" = "$twice" ]
}

@test "normalize_source of empty input is empty" {
  run normalize_source < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "between_markers extracts the block" {
  run between_markers < <(printf 'noise\n__BEGIN__\na\n\nb\n__END__\ntail\n')
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'a\n\nb')" ]
}

@test "between_markers fails without a begin marker" {
  run between_markers < <(printf 'ORA-01017: invalid username/password\n')
  [ "$status" -eq 2 ]
}

write_tns() {
  cat > "$BATS_TEST_TMPDIR/tnsnames.ora" <<'EOF'
# comment line
OTHER =
  (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = other)(PORT = 1521))
    (CONNECT_DATA = (SERVICE_NAME = other)))

PRODDB.WORLD, PRODDB_ALIAS =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = db.example.com)(PORT = 1522)) # inline comment
    (CONNECT_DATA =
      (SERVICE_NAME = prod.example.com)
    )
  )
EOF
}

@test "tns_descriptor finds an alias with a domain, case-insensitively" {
  write_tns
  run tns_descriptor proddb "$BATS_TEST_TMPDIR/tnsnames.ora"
  [ "$status" -eq 0 ]
  [ "$output" = "(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=db.example.com)(PORT=1522))(CONNECT_DATA=(SERVICE_NAME=prod.example.com)))" ]
}

@test "tns_descriptor finds the second name of an alias list and the first entry" {
  write_tns
  run tns_descriptor PRODDB_ALIAS "$BATS_TEST_TMPDIR/tnsnames.ora"
  [ "$output" = "(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=db.example.com)(PORT=1522))(CONNECT_DATA=(SERVICE_NAME=prod.example.com)))" ]
  run tns_descriptor OTHER "$BATS_TEST_TMPDIR/tnsnames.ora"
  [ "$output" = "(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=other)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=other)))" ]
}

@test "tns_descriptor fails for an unknown alias" {
  write_tns
  run tns_descriptor NOPE "$BATS_TEST_TMPDIR/tnsnames.ora"
  [ "$status" -eq 1 ]
}

@test "format_errors maps errors to file:line:col" {
  run format_errors <<'EOF'
PKG_CUSTOMER|PACKAGE BODY|38|31|PLS-00103: Encountered the symbol "END"
PKG_CUSTOMER|PACKAGE|3|5|PLS-00201: identifier 'X' must be declared

INVALID|PKG_CUSTOMER|PACKAGE BODY
EOF
  [ "${lines[0]}" = 'src/packages/pkg_customer.pkb:38:31: PLS-00103: Encountered the symbol "END"' ]
  [ "${lines[1]}" = "src/packages/pkg_customer.pks:3:5: PLS-00201: identifier 'X' must be declared" ]
  [ "${lines[2]}" = "PKG_CUSTOMER (PACKAGE BODY) is INVALID" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "format_errors trims the column padding SQLcl adds" {
  run format_errors < <(printf 'INVALID|PKG_A|PACKAGE BODY      \nPKG_A|PACKAGE|1|2|PLS-1: x     \n')
  [ "${lines[0]}" = "PKG_A (PACKAGE BODY) is INVALID" ]
  [ "${lines[1]}" = "src/packages/pkg_a.pks:1:2: PLS-1: x" ]
}

@test "normalize_source ignores a header comment before CREATE (no false drift)" {
  from_git="$(printf -- '-- Customer API\n-- owner: team\n\ncreate or replace package x as\n  p;\nend x;\n/\n' | normalize_source)"
  from_prod="$(printf 'package x as\n  p;\nend x;\n' | normalize_source)"
  [ "$from_git" = "$from_prod" ]
}

@test "normalize_source joins CREATE OR REPLACE written on its own line" {
  run normalize_source < <(printf 'create or replace\npackage x as\nend x;\n/\n')
  [ "${lines[0]}" = "CREATE OR REPLACE package x as" ]
  run normalize_source < <(printf 'CREATE\n  OR REPLACE EDITIONABLE\n  PACKAGE BODY x AS\nEND;\n')
  [ "${lines[0]}" = "CREATE OR REPLACE PACKAGE BODY x AS" ]
}

@test "format_errors maps standalone functions and procedures to their files" {
  run format_errors <<'EOF2'
FN_TOTAL|FUNCTION|3|9|PLS-00103: Encountered the symbol "END"
PR_TOUCH|PROCEDURE|2|1|PLS-00201: identifier 'X' must be declared
INVALID|FN_TOTAL|FUNCTION
EOF2
  [ "${lines[0]}" = 'src/functions/fn_total.fnc:3:9: PLS-00103: Encountered the symbol "END"' ]
  [ "${lines[1]}" = "src/procedures/pr_touch.prc:2:1: PLS-00201: identifier 'X' must be declared" ]
  [ "${lines[2]}" = "FN_TOTAL (FUNCTION) is INVALID" ]
}

@test "source_path maps object types to files and back" {
  [ "$(source_path pkg_a PACKAGE)" = "src/packages/pkg_a.pks" ]
  [ "$(source_path pkg_a 'PACKAGE BODY')" = "src/packages/pkg_a.pkb" ]
  [ "$(source_path fn_a FUNCTION)" = "src/functions/fn_a.fnc" ]
  [ "$(source_path pr_a PROCEDURE)" = "src/procedures/pr_a.prc" ]
  [ "$(source_name src/functions/fn_a.fnc)" = "fn_a" ]
  [ "$(source_name src/packages/pkg_a.pkb)" = "pkg_a" ]
}
