#!/usr/bin/env bash
# Run the bats unit tests inside a bash 3.2 container.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
docker build -q -t plsql-unit-test -f "$root/tests/unit/Dockerfile" "$root/tests/unit" >/dev/null
exec docker run --rm -v "$root":/repo:ro -w /repo plsql-unit-test bats tests/unit
