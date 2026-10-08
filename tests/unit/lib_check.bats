#!/usr/bin/env bats

setup() {
  load test_helper
  setup_lib
}

@test "explain_connect_error turns Oracle errors into .env advice" {
  run explain_connect_error <<< "ORA-01017: invalid credential or not authorized; logon denied"
  [[ "$output" == *"PROD_USER and PROD_PASSWORD"* ]] || false
  run explain_connect_error <<< "ORA-12514: Cannot connect to database. Service ORCLX is not registered"
  [[ "$output" == *"service name"* ]] || false
  [[ "$output" == *"PROD_CONNECT"* ]] || false
  run explain_connect_error <<< "ORA-12541: Cannot connect. No listener at host db port 1521"
  [[ "$output" == *"host and port"* ]] || false
  run explain_connect_error <<< "IO Error: The Network Adapter could not establish the connection (CONNECTION_ID=x)"
  [[ "$output" == *"host and port"* ]] || false
  run explain_connect_error <<< "ORA-17868: Unknown host specified.: nohost: Name or service not known"
  [[ "$output" == *"host name"* ]] || false
  run explain_connect_error <<< "ORA-28000: The account is locked."
  [[ "$output" == *"locked"* ]] || false
  run explain_connect_error <<< "ORA-28001: the password has expired"
  [[ "$output" == *"expired"* ]] || false
  run explain_connect_error <<< "something nobody expected"
  [[ "$output" == *"see the error above"* ]] || false
}

@test "check_connect_target warns about localhost inside Docker" {
  run check_connect_target "localhost:1521/FREEPDB1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"host.docker.internal"* ]] || false
  run check_connect_target "127.0.0.1:1521/X"
  [ "$status" -eq 1 ]
  run check_connect_target "db.example.com:1521/ORCLPDB1"
  [ "$status" -eq 0 ]
}

@test "check_connect_target rejects malformed EZConnect strings" {
  run check_connect_target "db.example.com"
  [ "$status" -eq 1 ]
  [[ "$output" == *"host:port/service"* ]] || false
  run check_connect_target "db.example.com:abc/X"
  [ "$status" -eq 1 ]
  run check_connect_target "db.example.com/ORCLPDB1"
  [ "$status" -eq 0 ]
}
