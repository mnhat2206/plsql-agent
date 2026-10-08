#!/usr/bin/env bats

setup() {
  load test_helper
  setup_lib
  export APP_SCHEMA=ecom_dev LOCAL_SYS_PASSWORD='p@ss w1' LOCAL_PORT=1530
  resolve_settings
}

@test "local_conn_info prints ready-to-paste connection details" {
  run local_conn_info
  [ "$status" -eq 0 ]
  [[ "$output" == *"Host        localhost"* ]] || false
  [[ "$output" == *"Port        1530"* ]] || false
  [[ "$output" == *"Service     FREEPDB1"* ]] || false
  [[ "$output" == *"User        ECOM_DEV"* ]] || false
  [[ "$output" == *"Password    p@ss w1"* ]] || false
  [[ "$output" == *"jdbc:oracle:thin:@//localhost:1530/FREEPDB1"* ]] || false
  [[ "$output" == *'ECOM_DEV/"p@ss w1"@//localhost:1530/FREEPDB1'* ]] || false
  [[ "$output" == *"(HOST = localhost)(PORT = 1530)"* ]] || false
  [[ "$output" == *"(SERVICE_NAME = FREEPDB1)"* ]] || false
}

@test "local_conn_info follows the XE service and a custom port" {
  unset LOCAL_IMAGE LOCAL_SERVICE
  export ORACLE_VERSION=21 LOCAL_PORT=1599
  resolve_settings
  run local_conn_info
  [[ "$output" == *"jdbc:oracle:thin:@//localhost:1599/XEPDB1"* ]] || false
}
