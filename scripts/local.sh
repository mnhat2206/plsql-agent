#!/usr/bin/env bash
# Container lifecycle for the local DB.
# usage: local.sh up|down|reset
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
resolve_settings
require_vars LOCAL_SYS_PASSWORD

compose() {
  docker compose -p "$COMPOSE_PROJECT" -f "$REPO_ROOT/docker/docker-compose.yml" "$@"
}

# compose_up PORT PORT_VARIABLE <compose args...>: like `compose ... up`, but a
# port clash (common: another Oracle on 1521) ends with a clear hint.
compose_up() {
  local port="$1" var="$2" log
  shift 2
  log="$(mktemp)"
  if ! compose "$@" 2>&1 | tee "$log"; then
    if grep -qE 'address already in use|port is already allocated' "$log"; then
      rm -f "$log"
      die "port $port is already used by another program (another Oracle database?). Set $var to a free port in .env, e.g. $var=$((port + 1))"
    fi
    rm -f "$log"
    exit 1
  fi
  rm -f "$log"
}

# Oracle sizes its memory for a server (about 2 GB here); a local test database
# runs fine with half. LOCAL_DB_MEMORY_MB (default 1024) is split 3/4 SGA,
# 1/4 PGA. Applied once (spfile), then the container is restarted.
limit_local_memory() {
  local mb="${LOCAL_DB_MEMORY_MB:-1024}" sga pga current
  if [[ ! "$mb" =~ ^[0-9]+$ ]] || ((mb < 768)); then
    die "LOCAL_DB_MEMORY_MB must be a number of MB, at least 768"
  fi
  sga=$((mb * 3 / 4))
  pga=$((mb - sga))
  current="$(printf "set heading off feedback off pagesize 0\nselect round(value / 1048576) from v\$parameter where name = 'sga_target';\n" \
    | docker exec -i "$LOCAL_HOST" sqlplus -s / as sysdba | tr -d '[:space:]')"
  if [[ "$current" == "$sga" ]]; then return 0; fi
  echo "limiting $LOCAL_HOST to ${mb} MB of memory (SGA ${sga} MB, PGA ${pga} MB); restarting it once..."
  printf 'alter system set sga_max_size = %sM scope = spfile;\nalter system set sga_target = %sM scope = spfile;\nalter system set pga_aggregate_target = %sM scope = spfile;\n' \
    "$sga" "$sga" "$pga" | docker exec -i "$LOCAL_HOST" sqlplus -s / as sysdba >/dev/null
  docker restart "$LOCAL_HOST" >/dev/null
  compose up -d --wait --wait-timeout 1200 oracle-local
}

case "${1:-}" in
  up)
    ensure_network
    ensure_sqlcl_image
    if [[ "$(docker inspect -f '{{.State.Running}}' "$LOCAL_HOST" 2>/dev/null)" != true ]]; then
      warn_low_memory 2500 "the local database" || true
    fi
    echo "starting $LOCAL_HOST ($LOCAL_IMAGE), first start can take a few minutes..."
    compose_up "$LOCAL_PORT" LOCAL_PORT up -d --wait --wait-timeout 1200 oracle-local
    limit_local_memory
    echo "local DB ready: localhost:$LOCAL_PORT/$LOCAL_SERVICE"
    ;;
  down)
    compose stop
    ;;
  reset)
    compose rm -sfv oracle-local
    docker volume rm -f "${COMPOSE_PROJECT}_oracle-local-data" >/dev/null
    echo "local DB deleted"
    ;;
  *)
    die "usage: local.sh up|down|reset"
    ;;
esac
