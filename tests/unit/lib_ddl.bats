#!/usr/bin/env bats

setup() {
  load test_helper
  setup_lib
}

@test "clean_ddl drops Data Pump load statements that GET_DDL appends after network import" {
  run clean_ddl < <(printf '%s\n' \
    '                ' \
    '  CREATE TABLE "APP"."EVENTS"   ' \
    '   ("EVENT_ID" NUMBER) ;' \
    'ALTER TABLE "APP"."EVENTS" ADD PRIMARY KEY ("EVENT_ID")' \
    '  USING INDEX  ENABLE;' \
    '  INSERT /*+  APPEND  NESTED_TABLE_SET_REFS  */ INTO     ' \
    '  "APP"."EVENTS"  KUT$ ("EVENT_ID")' \
    '  SELECT /*+ NESTED_TABLE_GET_REFS  */' \
    '  "EVENT_ID" FROM "APP"."EVENTS"@ KU$;   ' \
    '' \
    '  CREATE TABLE "APP"."T2" ("X" NUMBER) ;')
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' \
    '  CREATE TABLE "APP"."EVENTS"' \
    '   ("EVENT_ID" NUMBER) ;' \
    'ALTER TABLE "APP"."EVENTS" ADD PRIMARY KEY ("EVENT_ID")' \
    '  USING INDEX  ENABLE;' \
    '' \
    '  CREATE TABLE "APP"."T2" ("X" NUMBER) ;')" ]
}

@test "clean_ddl resets sequence start values so syncs give stable diffs" {
  run clean_ddl <<'EOF2'
CREATE SEQUENCE "APP"."S" MINVALUE 1 INCREMENT BY 1 START WITH 20041 CACHE 20 ;
EOF2
  [ "$output" = 'CREATE SEQUENCE "APP"."S" MINVALUE 1 INCREMENT BY 1 START WITH 1 CACHE 20 ;' ]
}
