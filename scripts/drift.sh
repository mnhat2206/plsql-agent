#!/usr/bin/env bash
# Compare a package, function or procedure on prod with its files at a git ref.
# usage: drift.sh <package_name> [git-ref=HEAD] [alt-ref]
# With alt-ref, the spec and the body may each match either ref (a deploy that
# stopped half way leaves the spec at the new commit and the body at the old).
# exit: 0 same, 1 different (diff on stderr unless DRIFT_QUIET=1), 2 error
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
resolve_settings
require_vars APP_SCHEMA PROD_USER PROD_PASSWORD
require_prod_target
[[ $# -ge 1 && -n "$1" ]] || die "usage: make drift PKG=<name> [REF=<git-ref>]" 2
validate_identifier "$1" name
validate_identifier "$APP_SCHEMA" schema
name="$1"
ref="${2:-HEAD}"
alt="${3:-}"
lower_name="$(lower "$name")"
cd "$REPO_ROOT"
git rev-parse --verify -q "$ref^{commit}" >/dev/null || die "unknown git ref: $ref" 2
if [[ -n "$alt" ]]; then
  git rev-parse --verify -q "$alt^{commit}" >/dev/null || die "unknown git ref: $alt" 2
fi
ensure_network
ensure_sqlcl_image
# Read every source type of this name from prod in one session.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fetch_prod_sources "$tmp" "$name" || die "could not read from prod" 2

# Normalized content of a file at a ref (empty when absent).
at_ref() {
  if git cat-file -e "$1:$2" 2>/dev/null; then git show "$1:$2" | normalize_source; fi
}

compare_one() {
  local type="$1" ext="$2" path prod="" expected=""
  path="$(source_path "$lower_name" "$type")"
  if [[ -f "$tmp/$lower_name.$ext" ]]; then prod="$(cat "$tmp/$lower_name.$ext")"; fi
  expected="$(at_ref "$ref" "$path")"
  if [[ "$prod" == "$expected" ]]; then return 0; fi
  if [[ -n "$alt" && "$prod" == "$(at_ref "$alt" "$path")" ]]; then return 0; fi
  if [[ "${DRIFT_QUIET:-0}" != 1 ]]; then
    echo "drift: $path at $ref differs from prod" >&2
    diff -u --label "$ref:$path" --label "prod:$(upper "$name") ($type)" \
      <(printf '%s\n' "$expected") <(printf '%s\n' "$prod") >&2 || true
  fi
  return 1
}

status=0
compare_one PACKAGE pks || status=1
compare_one 'PACKAGE BODY' pkb || status=1
compare_one FUNCTION fnc || status=1
compare_one PROCEDURE prc || status=1
if ((status == 0)); then echo "$lower_name: prod matches $ref${alt:+ or $alt}"; fi
exit "$status"
