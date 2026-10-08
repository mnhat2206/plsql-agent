#!/usr/bin/env bash
# Print the commit a CI deploy diffs from: the manual dispatch base if given,
# else the last successfully deployed commit (tag plsql-deployed), else the
# push's "before" commit. Using the tag means skipped, cancelled or failed
# runs are included in the next deploy.
# usage: ci_base.sh <dispatch-base> <push-before>
set -euo pipefail
if [[ -n "${1:-}" ]]; then
  echo "$1"
elif git rev-parse -q --verify 'refs/tags/plsql-deployed^{commit}' >/dev/null; then
  git rev-parse 'refs/tags/plsql-deployed^{commit}'
else
  echo "${2:-}"
fi
