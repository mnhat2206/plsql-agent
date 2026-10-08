#!/usr/bin/env bash
# Compile the packages changed between BASE and HEAD onto prod.
# Aborts before compiling anything if prod was changed outside git.
# usage: deploy.sh <base-sha> <head-sha>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
resolve_settings
require_vars APP_SCHEMA PROD_USER PROD_PASSWORD
require_prod_target
base="${1:-}"
head="${2:-}"
cd "$REPO_ROOT"

if [[ -z "$base" || "$base" =~ ^0+$ ]]; then
  echo "no base commit (first push?): nothing to deploy. Run 'make deploy BASE=<sha>' to deploy by hand."
  exit 0
fi
[[ -n "$head" ]] || die "usage: make deploy BASE=<sha> [HEAD=<sha>]"
git rev-parse --verify -q "$base^{commit}" >/dev/null || die "base commit $base not found (checkout with full history)"
git rev-parse --verify -q "$head^{commit}" >/dev/null || die "head commit $head not found"
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "$head^{commit}")" ]]; then
  die "the working tree is not at $head; check it out first"
fi
if [[ -n "$(git status --porcelain -- src/packages src/functions src/procedures)" ]]; then
  die "src/ has uncommitted changes"
fi

pkgs=()
while IFS= read -r p; do
  if [[ -n "$p" ]]; then pkgs+=("$p"); fi
done <<EOF
$(git diff --name-only --diff-filter=AMR "$base" "$head" -- 'src/packages/*.pks' 'src/packages/*.pkb' \
  'src/functions/*.fnc' 'src/procedures/*.prc' \
  | sed -E 's#^src/[a-z]+/##; s#\.(pks|pkb|fnc|prc)$##' | sort -u)
EOF
if ((${#pkgs[@]} == 0)); then
  echo "no source changes between $base and $head: nothing to deploy"
  exit 0
fi
echo "changed: ${pkgs[*]}"

drifted=()
for p in "${pkgs[@]}"; do
  rc=0
  # Spec and body may each be at BASE or already at HEAD (an earlier run that
  # stopped half way); anything else was changed outside git.
  "$SCRIPT_DIR/drift.sh" "$p" "$base" "$head" || rc=$?
  case "$rc" in
    0) ;;
    1) drifted+=("$p") ;;
    *) die "drift check failed for $p (could not reach prod)" 2 ;;
  esac
done

if ((${#drifted[@]} > 0)); then
  cat >&2 <<EOF
deploy aborted: prod was changed outside git for: ${drifted[*]}
Nothing was compiled. To fix:
  1. make pull PKG=<name>      # commits the prod version
  2. re-apply your change on top of it and open a new PR
EOF
  exit 1
fi

start="$(date +%s)"
"$SCRIPT_DIR/compile.sh" --target prod "${pkgs[@]}"

# Verify: prod must now hold exactly what is in HEAD.
mismatch=()
for p in "${pkgs[@]}"; do
  if ! "$SCRIPT_DIR/drift.sh" "$p" "$head" >/dev/null; then mismatch+=("$p"); fi
done
if ((${#mismatch[@]} > 0)); then
  die "deploy verification failed: prod does not match $head for: ${mismatch[*]} (run make drift PKG=<name> to see the difference)"
fi
echo "deployed ${#pkgs[@]} object(s) in $(($(date +%s) - start))s: ${pkgs[*]}"
