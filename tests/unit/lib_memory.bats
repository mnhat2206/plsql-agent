#!/usr/bin/env bats

setup() {
  load test_helper
  setup_lib
}

@test "sum_mem_usage_mb adds up docker stats MemUsage lines in any unit" {
  run sum_mem_usage_mb <<'EOF2'
2.541GiB / 7.654GiB
79.84MiB / 7.654GiB
512KiB / 7.654GiB
1.5GB / 7.654GiB
0B / 0B
EOF2
  [ "$status" -eq 0 ]
  # 2602 + 80 + 0.5 + 1430.5 (1.5e9 bytes) = 4113
  [ "$output" = "4113" ]
}

@test "sum_mem_usage_mb of nothing is 0" {
  run sum_mem_usage_mb < /dev/null
  [ "$output" = "0" ]
}
