#!/usr/bin/env bash
# Lint: shellcheck on every script and actionlint on the workflows (both in Docker).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
docker run --rm -v "$root":/mnt -w /mnt koalaman/shellcheck:stable -x \
  scripts/*.sh tests/lint.sh tests/unit/run.sh tests/integration/run.sh tests/integration/fakeprod-init/*.sh
docker run --rm -v "$root":/repo -w /repo rhysd/actionlint:latest -color
echo "lint OK"
