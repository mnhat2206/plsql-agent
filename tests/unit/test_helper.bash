# Loaded by every .bats file: `load test_helper` then `setup_lib`.
setup_lib() {
  # shellcheck source=../../scripts/lib.sh
  source "$BATS_TEST_DIRNAME/../../scripts/lib.sh"
}
