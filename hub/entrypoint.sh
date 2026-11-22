#!/usr/bin/env bash
set -euo pipefail
umask 077
app=${ORCA_HUB_APP:-/opt/Orca}
: "${ORCA_HUB_ADDRESS:?Set the gateway Tailscale WebSocket address}"
export ORCA_USER_DATA_PATH="${ORCA_USER_DATA_PATH:-$HOME/.config/orca}"
export ORCA_SERVE_RUNTIME=electron ORCA_BACKGROUND_LAUNCH=1
export ORCA_ELECTRON_NO_SANDBOX=1
unset ORCA_ENVIRONMENT ORCA_PAIRING_CODE ORCA_REMOTE_PAIRING ELECTRON_RUN_AS_NODE
unset DISPLAY WAYLAND_DISPLAY NODE_OPTIONS NODE_REPL_EXTERNAL_MODULE
mkdir -p "$ORCA_USER_DATA_PATH"
chmod 700 "$HOME" "$ORCA_USER_DATA_PATH"
if [[ ! -s "$HOME/.hub-instance-id" ]]; then
  uuid=$(< /proc/sys/kernel/random/uuid)
  printf '%s\n' "$uuid" > "$HOME/.hub-instance-id"
fi
export ORCA_INSTANCE_ID
ORCA_INSTANCE_ID=$(< "$HOME/.hub-instance-id")
# Start X11 before Chromium initializes; no desktop, VNC or host display is required.
xvfb-run -a -s '-screen 0 1280x800x24 -nolisten tcp' \
  "$app/resources/bin/orca-ide" serve --no-pairing --bind 0.0.0.0 \
  --port "${ORCA_HUB_PORT:-6768}" --pairing-address "$ORCA_HUB_ADDRESS" --refuse-public &
server=$!
script=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
env ELECTRON_RUN_AS_NODE=1 "$app/orca-ide" "$script/monitor.cjs" &
monitor=$!
bridge=''
if [[ ${ORCA_HUB_DISABLE_BRIDGE:-0} != 1 ]]; then
  env ELECTRON_RUN_AS_NODE=1 "$app/orca-ide" "$script/gateway-bridge.cjs" &
  bridge=$!
fi
pids=("$server" "$monitor")
if [[ -n "$bridge" ]]; then pids+=("$bridge"); fi
stop() {
  kill "${pids[@]}" 2>/dev/null || true
  wait "${pids[@]}" 2>/dev/null || true
}
trap 'stop; exit 0' TERM INT
set +e
wait -n "${pids[@]}"
code=$?
stop
(( code != 0 )) || code=1
exit "$code"
