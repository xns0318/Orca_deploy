#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/linux/common.sh"
source "$ROOT/versions.lock.env"
source "$ROOT/hub/image.sh"
require_commands docker sha256sum
image=''
hub_image_init
hub_image_verify
name="orca-hub-test-$$-$RANDOM"
namespace="$name-net"
volume="$name-home"
cleanup() {
  docker rm --force "$name" "$namespace" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT
wait_ready() {
  local deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    if docker exec "$name" hubctl health >/dev/null 2>&1; then return 0; fi
    [[ $(docker inspect --format '{{.State.Running}}' "$name") == true ]] || break
    sleep 2
  done
  docker logs --tail 80 "$name" >&2
  fail 'Hub image did not become healthy.'
}
# An isolated loopback namespace models the gateway sidecar without enrolling Tailscale.
docker run -d --name "$namespace" --network none --no-healthcheck --cap-drop ALL --read-only \
  --security-opt no-new-privileges:true --entrypoint /bin/sleep "$image" infinity >/dev/null
docker volume create "$volume" >/dev/null
docker run -d --name "$name" --network "container:$namespace" \
  --cap-drop ALL --security-opt no-new-privileges:true --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,size=268435456,mode=1777 --shm-size 256m \
  --mount "type=volume,src=$volume,dst=/home/orca" \
  --env ORCA_HUB_ADDRESS=ws://100.92.0.8:6768 --env ORCA_HUB_PORT=6768 --env ORCA_DESKTOP_PORT=6769 \
  "$image" >/dev/null
wait_ready
[[ $(docker exec "$name" id -u) == 10001 ]]
[[ $(docker exec "$name" stat -c %a /home/orca) == 700 ]]
[[ $(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$name") == true ]]
identity=$(docker exec "$name" cat /home/orca/.hub-instance-id)
observer=$(docker exec "$name" sha256sum /home/orca/.config/orca/hub-monitor.pairing.json)
[[ -n "$identity" && -n "$observer" ]]
docker exec "$name" hubctl pair --json >/dev/null
docker exec "$name" hubctl client add smoke-win >/dev/null
docker exec "$name" hubctl client list --active-names | grep -qx 'smoke-win'
docker exec "$name" hubctl client revoke smoke-win >/dev/null
docker restart --time 20 "$name" >/dev/null
wait_ready
[[ $(docker exec "$name" cat /home/orca/.hub-instance-id) == "$identity" ]]
[[ $(docker exec "$name" sha256sum /home/orca/.config/orca/hub-monitor.pairing.json) == "$observer" ]]
status_json=$(docker exec "$name" hubctl status)
printf '%s\n' "$status_json"
grep -q '"bridgeReady": true' <<< "$status_json"
printf 'PASS: real image runs non-root and read-only in a shared namespace; restart preserves identity, observer and desktop bridge.\n'
