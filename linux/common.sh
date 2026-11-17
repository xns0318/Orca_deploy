#!/usr/bin/env bash

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }

require_commands() {
  local command
  for command in "$@"; do
    command -v "$command" >/dev/null 2>&1 || fail "Required command missing: $command"
  done
}

server_release_version() {
  local key= value= extra= version=
  [[ -f "$1" && -r "$1" ]] || return 1
  # The official VERSION manifest has separate orca, orcad, node and target entries.
  while IFS=$' \t\r' read -r key value extra || [[ -n "$key$value$extra" ]]; do
    [[ "$key" == orca ]] || continue
    [[ -z "$version" && -z "$extra" && "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    version=$value
  done < "$1"
  [[ -n "$version" ]] || return 1
  printf '%s\n' "$version"
}

load_config() {
  [[ -f "$PREFIX/config.env" ]] || fail "No installation at $PREFIX"
  [[ -O "$PREFIX/config.env" ]] || fail 'Run this command as the user who installed Orca.'
  # This file is generated with Bash printf %q, inside the owner's private directory.
  source "$PREFIX/config.env"
  [[ "$INSTALL_UID" == "$(id -u)" && "$INSTALL_HOME" == "$HOME" ]] ||
    fail 'Use the original installation user and HOME so agent credentials stay in scope.'
  export ORCA_USER_DATA_PATH="$PREFIX/state"
  export ORCA_INSTANCE_ID="$INSTANCE_ID"
  export ORCA_BACKGROUND_LAUNCH=1
  unset ORCA_ENVIRONMENT ORCA_PAIRING_CODE ORCA_REMOTE_PAIRING ORCA_APP_EXECUTABLE
  ORCA_BIN="$PREFIX/current/bin/orca-ide"
}

bundle_node() {
  local digest
  [[ -f "$PREFIX/current/orcad/.runtime-node" ]] || fail 'The bundled Node marker is missing.'
  digest=$(<"$PREFIX/current/orcad/.runtime-node")
  [[ "$digest" =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'Invalid bundled Node marker.'
  NODE_BIN="$PREFIX/current/runtimes/node-$digest/bin/node"
  [[ -x "$NODE_BIN" ]] || fail 'The bundled Node executable is missing.'
}

process_start_time() {
  local stat rest
  local -a fields
  [[ -r "/proc/$1/stat" ]] || return 1
  stat=$(<"/proc/$1/stat") || return 1
  rest=${stat##*) }
  # /proc stat field 22; the prefix through field 2 may contain spaces.
  read -r -a fields <<< "$rest"
  [[ ${#fields[@]} -ge 20 && ${fields[0]} != Z ]] || return 1
  printf '%s' "${fields[19]}"
}

owned_server_running() {
  local pid started current entry matches=0
  [[ -f "$PREFIX/server.pid" ]] || return 1
  read -r pid started < "$PREFIX/server.pid" || return 1
  [[ "$pid" =~ ^[0-9]+$ && "$started" =~ ^[0-9]+$ ]] || return 1
  current=$(process_start_time "$pid") || return 1
  [[ "$current" == "$started" && -r "/proc/$pid/environ" ]] || return 1
  while IFS= read -r -d '' entry; do
    [[ "$entry" == "ORCA_DEPLOY_PREFIX=$PREFIX" ]] && matches=1
  done < "/proc/$pid/environ"
  [[ "$matches" == 1 ]] || return 1
  SERVER_PID=$pid
}

rpc() {
  timeout 20 "$ORCA_BIN" "$@"
}

health_check() {
  timeout 3 "$ORCA_BIN" status --json 2>/dev/null |
    "$NODE_BIN" "$PREFIX/lib/rpc-result.mjs" health >/dev/null 2>&1
}
