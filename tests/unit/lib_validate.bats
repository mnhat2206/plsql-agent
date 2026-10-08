#!/usr/bin/env bats

setup() {
  load test_helper
  setup_lib
  mkdir -p "$BATS_TEST_TMPDIR/src/packages"
  cd "$BATS_TEST_TMPDIR"
}

pkg_file() { printf '%s\n' "$@" > "src/packages/$F"; }

@test "validate_source_file accepts a well-formed spec and body" {
  F=pkg_a.pks pkg_file '-- header' 'create or replace package pkg_a as' '  procedure p;' 'end pkg_a;' '/'
  run validate_source_file src/packages/pkg_a.pks
  [ "$status" -eq 0 ]
  F=pkg_a.pkb pkg_file 'CREATE OR REPLACE EDITIONABLE PACKAGE BODY "PKG_A" AS' 'end;' '/'
  run validate_source_file src/packages/pkg_a.pkb
  [ "$status" -eq 0 ]
  F=pkg_b.pkb pkg_file 'CREATE OR REPLACE PACKAGE BODY app.pkg_b AS' 'end;' '/'
  run validate_source_file src/packages/pkg_b.pkb
  [ "$status" -eq 0 ]
}

@test "validate_source_file rejects statements after the package" {
  F=pkg_a.pks pkg_file 'create or replace package pkg_a as' 'end;' '/' 'grant execute on pkg_a to public;'
  run validate_source_file src/packages/pkg_a.pks
  [ "$status" -eq 1 ]
  [[ "$output" == *"src/packages/pkg_a.pks: only one unit allowed"* ]] || false
  F=pkg_a.pks pkg_file 'create or replace package pkg_a as' 'end;' '/' 'drop table t' '/'
  run validate_source_file src/packages/pkg_a.pks
  [ "$status" -eq 1 ]
}

@test "validate_source_file rejects anything before CREATE except comments" {
  F=pkg_a.pks pkg_file 'host rm -rf /' 'create or replace package pkg_a as' 'end;' '/'
  run validate_source_file src/packages/pkg_a.pks
  [ "$status" -eq 1 ]
  [[ "$output" == *"must start with CREATE OR REPLACE PACKAGE pkg_a"* ]] || false
  F=pkg_a.pks pkg_file '/* x */ drop table t;' 'create or replace package pkg_a as' 'end;' '/'
  run validate_source_file src/packages/pkg_a.pks
  [ "$status" -eq 1 ]
}

@test "validate_source_file rejects a package that does not match its file" {
  F=pkg_a.pks pkg_file 'create or replace package pkg_b as' 'end;' '/'
  run validate_source_file src/packages/pkg_a.pks
  [ "$status" -eq 1 ]
  F=pkg_a.pks pkg_file 'create or replace package body pkg_a as' 'end;' '/'
  run validate_source_file src/packages/pkg_a.pks
  [ "$status" -eq 1 ]
  F=pkg_a.pkb pkg_file 'create or replace package pkg_a as' 'end;' '/'
  run validate_source_file src/packages/pkg_a.pkb
  [ "$status" -eq 1 ]
  F=pkg_ab.pks pkg_file 'create or replace package pkg_a as' 'end;' '/'
  run validate_source_file src/packages/pkg_ab.pks
  [ "$status" -eq 1 ]
}

@test "validate_source_file rejects bad file names" {
  F="a'b.pks" pkg_file 'create or replace package x as' 'end;' '/'
  run validate_source_file "src/packages/a'b.pks"
  [ "$status" -eq 1 ]
  F=PKG_A.pks pkg_file 'create or replace package pkg_a as' 'end;' '/'
  run validate_source_file src/packages/PKG_A.pks
  [ "$status" -eq 1 ]
  [[ "$output" == *"lower case"* ]] || false
}

@test "validate_source_file accepts standalone functions and procedures" {
  mkdir -p src/functions src/procedures
  printf '%s\n' '-- header' 'create or replace function fn_total(p_id number) return number is' 'begin return 1; end;' '/' > src/functions/fn_total.fnc
  run validate_source_file src/functions/fn_total.fnc
  [ "$status" -eq 0 ]
  printf '%s\n' 'CREATE OR REPLACE EDITIONABLE PROCEDURE "PR_TOUCH" AS' 'begin null; end;' '/' > src/procedures/pr_touch.prc
  run validate_source_file src/procedures/pr_touch.prc
  [ "$status" -eq 0 ]
}

@test "validate_source_file rejects a function file holding a procedure or another name" {
  mkdir -p src/functions
  printf '%s\n' 'create or replace procedure fn_total as begin null; end;' '/' > src/functions/fn_total.fnc
  run validate_source_file src/functions/fn_total.fnc
  [ "$status" -eq 1 ]
  [[ "$output" == *"must start with CREATE OR REPLACE FUNCTION fn_total"* ]] || false
  printf '%s\n' 'create or replace function fn_other return number is begin return 1; end;' '/' > src/functions/fn_total.fnc
  run validate_source_file src/functions/fn_total.fnc
  [ "$status" -eq 1 ]
}
