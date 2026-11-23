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
    'Run on the Docker host. Installs the shared gateway, persistent mobile hub and Windows desktop bridge.' \
    '  --name NAME             Hub container name (default: orca-hub)' \
    '  --gateway-name NAME     Existing/new gateway (default: orca-gateway)' \
    '  --network NAME          Gateway bridge network; repeat for multiple networks' \
    '  --auth-key-file FILE    Only needed when first enrolling the Tailscale gateway' \
    '  --port PORT             Stable tailnet and local mobile hub port (default: 6768)' \
    '  --desktop-port PORT     Stable tailnet and local Windows gateway bridge port (default: 6769)' \
    '  --wait-seconds N        Startup timeout (default: 120)' \
    '  --image-archive FILE    Load an exported hub image; no hub build/download' \
    '  --image-sha256 DIGEST   Archive SHA256 (default: read adjacent FILE.sha256)' \
    '  --reuse-local-base      Build hub updates/upgrades without Docker Hub on top of an existing local hub image' \
    '  --hub-deb FILE          Pre-downloaded official orca-ide_<ver>_<arch>.deb (implies --reuse-local-base, fully offline)' \
    '  --recreate              Recreate this owned hub after image/config changes; keep its volume' \
    '  --dry-run               Inspect only; no builds or configuration changes'
}
name=orca-hub gateway=orca-gateway port=6768 desktop_port='' wait_seconds=120 dry_run=0 recreate=0 reuse_local_base=0
archive='' archive_digest='' hub_deb='' image=''
gateway_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name|--gateway-name|--network|--auth-key-file|--port|--desktop-port|--wait-seconds|--image-archive|--image-sha256|--hub-deb)
      [[ $# -ge 2 && -n "$2" ]] || fail "Missing value for $1"
      case "$1" in
        --name) name=$2 ;;
        --gateway-name) gateway=$2 ;;
        --port) port=$2 ;;
        --desktop-port) desktop_port=$2 ;;
        --wait-seconds) wait_seconds=$2 ;;
        --image-archive) archive=$2 ;;
        --image-sha256) archive_digest=$2 ;;
        --hub-deb) hub_deb=$2; reuse_local_base=1 ;;
        *) gateway_args+=("$1" "$2") ;;
      esac
      shift 2 ;;
    --reuse-local-base) reuse_local_base=1; shift ;;
    --recreate) recreate=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done
[[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ && "$gateway" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ && "$name" != "$gateway" ]] || fail 'Use distinct valid hub and gateway names.'
[[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) || fail 'Invalid port.'
if [[ -z "$desktop_port" ]]; then
  if (( port == 65535 )); then desktop_port=65534; else desktop_port=$((port + 1)); fi
fi
[[ "$desktop_port" =~ ^[1-9][0-9]{0,4}$ ]] && (( desktop_port <= 65535 )) || fail 'Invalid desktop port.'
[[ "$desktop_port" != "$port" ]] || fail 'Hub port and desktop bridge port must differ.'
[[ "$wait_seconds" =~ ^[1-9][0-9]{0,2}$ ]] || fail '--wait-seconds must be 1-999.'
require_commands docker sha256sum flock
[[ -n "$archive" || -z "$archive_digest" ]] || fail '--image-sha256 requires --image-archive.'
[[ -z "$archive" || "$reuse_local_base" != 1 ]] || fail 'Choose either --image-archive or --reuse-local-base, not both.'
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
note "Hub: $name; persistent home: $volume; mobile port: $port; Windows bridge port: $desktop_port"
note 'Full Electron serve runtime + transparent WS desktop bridge; no host ports, host display or Docker socket mount.'
if [[ "$dry_run" == 1 ]]; then exit 0; fi

state_dir="${XDG_DATA_HOME:-$HOME/.local/share}/orca-gateway/$gateway"
exec 8>"$state_dir/hub-install.lock"
flock -n 8 || fail 'Another hub installation is in progress.'
gateway_id=$(docker container inspect --format '{{.Id}}' "$gateway")
gateway_ip=$(docker exec "$gateway" tailscale ip -4)
[[ "$gateway_ip" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Expected one Tailscale IPv4 address.'
address="ws://$gateway_ip:$port"
desktop_url="http://$gateway_ip:$desktop_port"
hub_image_init
existing_image=''
if [[ "$existing" == 1 ]]; then
  changed=0
  existing_image=$(docker container inspect --format '{{.Config.Image}}' "$name")
  [[ "$existing_image" == "$image" &&
     $(docker container inspect --format '{{.HostConfig.NetworkMode}}' "$name") == "container:$gateway_id" &&
     $(docker container inspect --format '{{index .Config.Labels "com.orca-deploy.address"}}' "$name") == "$address" &&
     $(docker container inspect --format '{{index .Config.Labels "com.orca-deploy.desktop-port"}}' "$name") == "$desktop_port" ]] || changed=1
  if [[ "$changed" == 1 && "$recreate" != 1 ]]; then
    fail 'Hub image or gateway namespace changed. Rerun with --recreate to replace only the hub and preserve its volume.'
  fi
fi
if ! docker image inspect "$image" >/dev/null 2>&1; then
  if [[ -n "$archive" ]]; then
    docker image load --input "$archive"
  elif [[ "$reuse_local_base" == 1 ]]; then
    if [[ -z "$hub_deb" ]] && base_hub_image=$(hub_find_local_base_image "$existing_image" 0); then
      hub_image_build_overlay "$base_hub_image"
    else
      base_hub_image=$(hub_find_local_base_image "$existing_image" 1) ||
        fail "No local base image matching orca-deploy-hub:*-$arch-* found. Load a prior hub archive first (docker image load --input ...) or use --image-archive."
      hub_image_build_upgrade "$base_hub_image" "$hub_deb"
    fi
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
    --label "com.orca-deploy.address=$address" --label "com.orca-deploy.desktop-port=$desktop_port" \
    --mount "type=volume,src=$volume,dst=/home/orca" \
    --env "ORCA_HUB_ADDRESS=$address" --env "ORCA_HUB_PORT=$port" --env "ORCA_DESKTOP_PORT=$desktop_port" \
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
# Validate both TCP listeners before modifying Serve. Never reset unrelated Serve services.
serve_json=$(docker exec "$gateway" tailscale serve status --json)
printf '%s' "$serve_json" | docker exec -i "$name" hubctl check-serve "$port"
printf '%s' "$serve_json" | docker exec -i "$name" hubctl check-serve "$desktop_port"
docker exec "$gateway" tailscale serve --bg --yes --tcp="$port" "tcp://127.0.0.1:$port"
docker exec "$gateway" tailscale serve --bg --yes --tcp="$desktop_port" "tcp://127.0.0.1:$desktop_port"
serve_after=$(docker exec "$gateway" tailscale serve status --json)
printf '%s' "$serve_after" | docker exec -i "$name" hubctl check-serve "$port" --required
printf '%s' "$serve_after" | docker exec -i "$name" hubctl check-serve "$desktop_port" --required
note "Hub ready locally. Stable mobile endpoint: $address"
note "Windows desktop gateway bridge: $desktop_url"
note "Enroll a container: bash hub/connect.sh --container CONTAINER --name NODE_NAME --hub $name"
note "Pair your phone once: docker exec -it $name hubctl pair"
note "Register a Windows client: docker exec $name hubctl client add win-1"
note 'Acceptance still requires a tailnet policy allowing both gateway TCP ports. No public Funnel was enabled.'
