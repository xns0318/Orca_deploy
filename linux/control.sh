#!/usr/bin/env bash
set -euo pipefail
umask 077
PREFIX=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$PREFIX/lib/common.sh"
require_commands timeout flock nohup
load_config
bundle_node

start_server() {
  if owned_server_running; then
    health_check || fail "The process is running but RPC is unhealthy. Check $PREFIX/logs/server.log"
    note 'Orca is already running; existing sessions and pairing are unchanged.'
    return
  fi
  mkdir -p "$PREFIX/logs"
  nohup env ORCA_DEPLOY_PREFIX="$PREFIX" "$PREFIX/bin/orca-service" run \
    >>"$PREFIX/logs/server.log" 2>&1 </dev/null &
  local child=$! attempt
  for attempt in {1..30}; do
    if owned_server_running && health_check; then
      note "Orca is ready. PID: $SERVER_PID"
      return
    fi
    if ! kill -0 "$child" 2>/dev/null; then
      wait "$child" || true
      fail "Orca exited during startup. Check $PREFIX/logs/server.log"
    fi
    sleep 1
  done
  fail "Orca startup timed out. The process was left for inspection. Check $PREFIX/logs/server.log"
}

stop_server() {
  if ! owned_server_running; then
    note 'No running server owned by this installation.'
    return
  fi
  kill -TERM "$SERVER_PID"
  local attempt
  for attempt in {1..30}; do
    if ! owned_server_running; then
      rm -f -- "$PREFIX/server.pid"
      note 'Orca server stopped. Its persistent profile was kept.'
      return
    fi
    sleep 1
  done
  fail 'The server has not stopped after 30 seconds. No force-kill was performed.'
}

action=${1:-status}
[[ $# -eq 0 ]] || shift
case "$action" in
  run)
    # Re-exec with a stable ownership marker in /proc, also for direct foreground use.
    if [[ ${ORCA_DEPLOY_PREFIX:-} != "$PREFIX" ]]; then
      exec env ORCA_DEPLOY_PREFIX="$PREFIX" "$PREFIX/bin/orca-service" run
    fi
    exec 9>"$PREFIX/server.lock"
    flock -n 9 || fail 'This Orca service is already running.'
    printf '%s %s\n' "$$" "$(process_start_time "$$")" > "$PREFIX/server.pid"
    exec "$ORCA_BIN" serve --supervise --no-pairing --bind 0.0.0.0 \
      --port "$LISTEN_PORT" --pairing-address "$ADVERTISE_ADDRESS" --refuse-public
    ;;
  start) start_server ;;
  stop) stop_server ;;
  restart) stop_server; start_server ;;
  status)
    owned_server_running || fail 'This installation has no running server.'
    health_check || fail 'Orca RPC is unhealthy.'
    rpc status --json
    ;;
  pair)
    owned_server_running && health_check || fail 'Start the server before creating a pairing offer.'
    if [[ ${1:-} == --mobile ]]; then
      rpc pair --mobile --address "$ADVERTISE_ADDRESS"
    else
      [[ $# -eq 0 ]] || fail 'Usage: orca-service pair [--mobile]'
      temporary=$(mktemp "$PREFIX/.pairing.XXXXXX")
      trap 'rm -f -- "$temporary"' EXIT
      rpc pair --address "$ADVERTISE_ADDRESS" --json |
        "$NODE_BIN" "$PREFIX/lib/rpc-result.mjs" pair > "$temporary"
      chmod 600 "$temporary"
      mv -f -- "$temporary" "$PREFIX/server.pairing.json"
      note "Pairing saved privately: $PREFIX/server.pairing.json"
      note 'Transfer this file privately to Windows. Generate a fresh offer for each new client.'
    fi
    ;;
  logs) exec tail -n 100 -f "$PREFIX/logs/server.log" ;;
  cli) exec "$ORCA_BIN" "$@" ;;
  *) fail 'Usage: orca-service {start|stop|restart|run|status|pair|logs|cli}' ;;
esac
