#!/usr/bin/env bash
# Pull packages, standalone functions and procedures from prod into src/ and
# commit what differs, in one commit. Everything is read with a single query,
# so --all is fast even for schemas with thousands of objects.
# usage: pull.sh <name> [name ...] | pull.sh --all
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
resolve_settings
require_vars APP_SCHEMA PROD_USER PROD_PASSWORD
require_prod_target
validate_identifier "$APP_SCHEMA" schema
[[ $# -ge 1 && -n "$1" ]] || die "usage: make pull PKG=<package_name> [PKG=\"a b\"]  |  make pull-all"
cd "$REPO_ROOT"
ensure_network
ensure_sqlcl_image

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

names=()
if [[ "$1" == "--all" ]]; then
  fetch_prod_sources "$tmp" || die "could not read from prod" 2
  while IFS= read -r n; do
    if [[ -n "$n" ]]; then names+=("$n"); fi
  done <<EOF
$(for f in "$tmp"/*.pks "$tmp"/*.fnc "$tmp"/*.prc; do if [[ -f "$f" ]]; then source_name "$f"; fi; done | sort -u)
EOF
else
  for p in "$@"; do
    validate_identifier "$p" name
    names+=("$(lower "$p")")
  done
  fetch_prod_sources "$tmp" "${names[@]}" || die "could not read from prod" 2
  for n in "${names[@]}"; do
    if [[ ! -f "$tmp/$n.pks" && ! -f "$tmp/$n.fnc" && ! -f "$tmp/$n.prc" ]]; then
      die "$(upper "$n") not found in schema $(upper "$APP_SCHEMA") on prod (no package, function or procedure)"
    fi
  done
fi
if ((${#names[@]} == 0)); then
  echo "no packages, functions or procedures in schema $(upper "$APP_SCHEMA") on prod"
  exit 0
fi

paths=()
for n in "${names[@]}"; do
  paths+=("src/packages/$n.pks" "src/packages/$n.pkb" "src/functions/$n.fnc" "src/procedures/$n.prc")
done
dirty="$(git status --porcelain -- "${paths[@]}")"
if [[ -n "$dirty" ]]; then
  printf '%s\n' "$dirty" >&2
  die "the files above have uncommitted changes; commit or stash them before pulling"
fi

# ALL_SOURCE hides a body from users without enough privileges, so "no body"
# is not proof that it was dropped: never delete a tracked body file.
hidden=""
for n in "${names[@]}"; do
  if [[ ! -f "$tmp/$n.pkb" ]] && git ls-files --error-unmatch "src/packages/$n.pkb" >/dev/null 2>&1; then
    hidden="$hidden $n"
  fi
done
if [[ -n "$hidden" ]]; then
  die "the package body is not visible on prod for:$hidden (dropped, or PROD_USER lacks the privilege to see it); keeping the .pkb files"
fi

added=()
for n in "${names[@]}"; do
  if [[ -z "$(git ls-files -- "src/packages/$n.pks" "src/functions/$n.fnc" "src/procedures/$n.prc")" ]]; then added+=("$n"); fi
  for ext in pks pkb fnc prc; do
    if [[ -f "$tmp/$n.$ext" ]]; then
      case "$ext" in pks | pkb) dir=src/packages ;; fnc) dir=src/functions ;; prc) dir=src/procedures ;; esac
      mkdir -p "$dir"
      cp "$tmp/$n.$ext" "$dir/$n.$ext"
    fi
  done
done

stage=()
for f in "${paths[@]}"; do
  if [[ -f "$f" ]]; then stage+=("$f"); fi
done
git add -- "${stage[@]}"
changed="$(git diff --cached --name-only -- "${stage[@]}" | sed -E 's#^src/[a-z]+/##; s#\.(pks|pkb|fnc|prc)$##' | sort -u)"
if [[ -z "$changed" ]]; then
  echo "${#names[@]} object(s) up to date with prod"
  exit 0
fi

count="$(printf '%s\n' "$changed" | grep -c .)"
added_list=" ${added[*]+${added[*]}} "
new=""
drifted=""
while IFS= read -r n; do
  case "$added_list" in
    *" $n "*) new="$new $n" ;;
    *) drifted="$drifted $n" ;;
  esac
done <<EOF2
$changed
EOF2
if ((count == 1)); then
  if [[ -n "$new" ]]; then msg="sync(prod): add${new}"; else msg="sync(prod):${drifted} drift from prod"; fi
  git commit -q --only -m "$msg" -- "${stage[@]}"
else
  msg="sync(prod): pull $count objects from prod"
  body=""
  if [[ -n "$new" ]]; then body="added:${new}"$'\n'; fi
  if [[ -n "$drifted" ]]; then body="${body}changed on prod:${drifted}"$'\n'; fi
  git commit -q --only -m "$msg" -m "$body" -- "${stage[@]}"
fi
echo "committed '$msg'"
if [[ -n "$drifted" ]]; then echo "changed on prod outside git:$drifted"; fi
