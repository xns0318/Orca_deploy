#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/linux/common.sh"
source "$ROOT/versions.lock.env"
source "$ROOT/hub/image.sh"
usage() {
  printf '%s\n' \
    'Usage: bash hub/install.sh [--network bridge ...] [options]' \
    'Run on the Docker host. Installs the shared gateway and persistent mobile aggregation hub.' \
    '  --name NAME             Hub container name (default: orca-hub)' \
    '  --gateway-name NAME     Existing/new gateway (default: orca-gateway)' \
    '  --network NAME          Gateway bridge network; repeat for multiple networks' \
    '  --auth-key-file FILE    Only needed when first enrolling the Tailscale gateway' \
    '  --port PORT             Stable tailnet and local hub port (default: 6768)' \
    '  --wait-seconds N        Startup timeout (default: 120)' \
    '  --image-archive FILE    Load an exported hub image; no hub build/download' \
    '  --image-sha256 DIGEST   Archive SHA256 (default: read adjacent FILE.sha256)' \
    '  --recreate              Recreate this owned hub after image/config changes; keep its volume' \
    '  --dry-run               Inspect only; no builds or configuration changes'
}
name=orca-hub gateway=orca-gateway port=6768 wait_seconds=120 dry_run=0 recreate=0
archive='' archive_digest='' image=''
gateway_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name|--gateway-name|--network|--auth-key-file|--port|--wait-seconds|--image-archive|--image-sha256)
      [[ $# -ge 2 && -n "$2" ]] || fail "Missing value for $1"
      case "$1" in
        --name) name=$2 ;;
        --gateway-name) gateway=$2 ;;
        --port) port=$2 ;;
        --wait-seconds) wait_seconds=$2 ;;
        --image-archive) archive=$2 ;;
        --image-sha256) archive_digest=$2 ;;
        *) gateway_args+=("$1" "$2") ;;
      esac
      shift 2 ;;
    --recreate) recreate=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done
[[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ && "$gateway" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ && "$name" != "$gateway" ]] || fail 'Use distinct valid hub and gateway names.'
[[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) || fail 'Invalid port.'
[[ "$wait_seconds" =~ ^[1-9][0-9]{0,2}$ ]] || fail '--wait-seconds must be 1-999.'
require_commands docker sha256sum flock
[[ -n "$archive" || -z "$archive_digest" ]] || fail '--image-sha256 requires --image-archive.'
if [[ -n "$archive" ]]; then hub_archive_verify "$archive" "$archive_digest"; fi
role=orca-mobile-hub-v1 volume="$name-home"
existing=0
if docker container inspect "$name" >/dev/null 2>&1; then
  existing=1
  [[ $(docker container inspect --format '{{index .Config.Labels "com.orca-deploy.role"}}' "$name") == "$role" ]] || fail "Container $name belongs to another deployment."
  [[ $(docker container inspect --format '{{range .Mounts}}{{if eq .Destination "/home/orca"}}{{.Name}}{{end}}{{end}}' "$name") == "$volume" ]] || fail 'Unexpected hub state mount.'
fi
if docker volume inspect "$volume" >/dev/null 2>&1; then
  [[ $(docker volume inspect --format '{{index .Labels "com.orca-deploy.hub"}}' "$volume") == "$name" ]] || fail "Volume $volume belongs to another deployment."
elif [[ "$existing" == 1 ]]; then
  fail 'The hub state volume is missing. Inspect the deployment before continuing.'
fi
if [[ "$dry_run" == 1 ]]; then gateway_args+=(--dry-run); fi
bash "$ROOT/gateway/install.sh" --name "$gateway" "${gateway_args[@]}"
note "Hub: $name; persistent home: $volume; gateway TCP port: $port"
note 'Full Electron serve runtime; no Windows dependency, host ports, host display or Docker socket mount.'
if [[ "$dry_run" == 1 ]]; then exit 0; fi

state_dir="${XDG_DATA_HOME:-$HOME/.local/share}/orca-gateway/$gateway"
exec 8>"$state_dir/hub-install.lock"
flock -n 8 || fail 'Another hub installation is in progress.'
gateway_id=$(docker container inspect --format '{{.Id}}' "$gateway")
gateway_ip=$(docker exec "$gateway" tailscale ip -4)
[[ "$gateway_ip" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Expected one Tailscale IPv4 address.'
address="ws://$gateway_ip:$port"
hub_image_init
if [[ "$existing" == 1 ]]; then
  changed=0
  [[ $(docker container inspect --format '{{.Config.Image}}' "$name") == "$image" &&
     $(docker container inspect --format '{{.HostConfig.NetworkMode}}' "$name") == "container:$gateway_id" &&
     $(docker container inspect --format '{{index .Config.Labels "com.orca-deploy.address"}}' "$name") == "$address" ]] || changed=1
  if [[ "$changed" == 1 && "$recreate" != 1 ]]; then
    fail 'Hub image or gateway namespace changed. Rerun with --recreate to replace only the hub and preserve its volume.'
  fi
fi
if ! docker image inspect "$image" >/dev/null 2>&1; then
  if [[ -n "$archive" ]]; then
    docker image load --input "$archive"
  else
    hub_image_build
  fi
fi
hub_image_verify
if [[ "$existing" == 1 && ${changed:-0} == 1 ]]; then
  docker stop --time 30 "$name" >/dev/null
  docker rm "$name" >/dev/null
  existing=0
fi
if [[ "$existing" == 0 ]]; then
  docker volume create --label "com.orca-deploy.hub=$name" "$volume" >/dev/null
  docker create --name "$name" --restart unless-stopped --network "container:$gateway_id" \
    --cap-drop ALL --security-opt no-new-privileges:true --read-only \
    --tmpfs /tmp:rw,nosuid,nodev,size=268435456,mode=1777 --shm-size 256m \
    --label "com.orca-deploy.role=$role" --label "com.orca-deploy.gateway=$gateway" \
    --label "com.orca-deploy.address=$address" \
    --mount "type=volume,src=$volume,dst=/home/orca" \
    --env "ORCA_HUB_ADDRESS=$address" --env "ORCA_HUB_PORT=$port" \
    --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
    "$image" >/dev/null
fi
if [[ $(docker container inspect --format '{{.State.Running}}' "$name") != true ]]; then
  docker start "$name" >/dev/null
fi
deadline=$((SECONDS + wait_seconds))
ready=0
while (( SECONDS < deadline )); do
  state=$(docker container inspect --format '{{.State.Status}}' "$name")
  [[ "$state" == running ]] || fail "Hub is $state. Inspect: docker logs $name"
  if docker exec "$name" hubctl health >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
[[ "$ready" == 1 ]] || fail "Hub startup timed out; state was kept. Inspect: docker logs $name"
docker exec "$name" hubctl name "$name"
# Change only this TCP listener. Never reset the gateway's other Serve services.
docker exec "$gateway" tailscale serve status --json | docker exec -i "$name" hubctl check-serve "$port"
docker exec "$gateway" tailscale serve --bg --yes --tcp="$port" "tcp://127.0.0.1:$port"
docker exec "$gateway" tailscale serve status --json | docker exec -i "$name" hubctl check-serve "$port" --required
note "Hub ready locally. Stable mobile endpoint: $address"
note "Enroll a container: bash hub/connect.sh --container CONTAINER --name NODE_NAME --hub $name"
note "Pair your phone once: docker exec -it $name hubctl pair"
note 'Phone acceptance still requires a tailnet policy allowing the gateway TCP port. No public Funnel was enabled.'
