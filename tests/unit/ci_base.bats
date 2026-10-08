#!/usr/bin/env bats
# scripts/ci_base.sh picks the commit the deploy diffs from.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/ci_base.sh"
  cd "$BATS_TEST_TMPDIR"
  git init -q -b main repo && cd repo
  git config user.email t@example.com && git config user.name t
  git commit -q --allow-empty -m one && ONE="$(git rev-parse HEAD)"
  git commit -q --allow-empty -m two && TWO="$(git rev-parse HEAD)"
}

@test "without a deployed tag the push's before commit is used" {
  run "$SCRIPT" "" "$ONE"
  [ "$status" -eq 0 ]
  [ "$output" = "$ONE" ]
}

@test "the last deployed tag wins over the push's before commit (skipped or failed runs are included)" {
  git tag plsql-deployed "$ONE"
  run "$SCRIPT" "" "$TWO"
  [ "$output" = "$ONE" ]
}

@test "a manual dispatch base wins over everything" {
  git tag plsql-deployed "$ONE"
  run "$SCRIPT" "$TWO" "$ONE"
  [ "$output" = "$TWO" ]
}
