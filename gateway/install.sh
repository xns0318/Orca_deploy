#!/usr/bin/env bash
# Hidden key input must stay out of inherited shell tracing.
set +x
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/linux/common.sh"
source "$ROOT/linux/network.sh"

usage() {
  printf '%s\n' \
    'Usage: bash gateway/install.sh [--network NETWORK ...] [options]' \
    'Run on the Linux Docker host. Creates one shared Tailscale gateway container.' \
    '  --network NAME       Existing bridge network; repeat for several networks (default: bridge)' \
    '  --name NAME          Gateway container/host name (default: orca-gateway)' \
    '  --auth-key-file FILE Private auth-key file outside this repository; otherwise prompt on first install' \
    '  --wait-seconds N     Wait for local gateway health (default: 120)' \
    '  --dry-run            Read Docker configuration and show the plan; change nothing' \
    '  --help               Show help'
}

name=orca-gateway auth_file= wait_seconds=120 dry_run=0
networks=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --network|--name|--auth-key-file|--wait-seconds)
      [[ $# -ge 2 && -n "$2" ]] || fail "Missing value for $1"
      case "$1" in
        --network) networks+=("$2") ;;
        --name) name=$2 ;;
        --auth-key-file) auth_file=$2 ;;
        --wait-seconds) wait_seconds=$2 ;;
      esac
      shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done
[[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || fail 'Use a gateway name of 1-63 letters, digits or hyphens.'
[[ "$wait_seconds" =~ ^[1-9][0-9]{0,2}$ ]] || fail '--wait-seconds must be 1-999.'
[[ ${#networks[@]} -gt 0 ]] || networks=(bridge)
[[ $(uname -s) == Linux ]] || fail 'Run this installer on the Linux Docker host.'
require_commands docker sort readlink stat flock
if [[ -n ${DOCKER_CONTEXT:-} || -z ${DOCKER_HOST:-} ]]; then
  endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}')
else
  endpoint=$DOCKER_HOST
fi
[[ "$endpoint" == unix://* ]] || fail 'Run on the target Docker host using its local Unix socket.'
[[ $(docker version --format '{{.Server.Os}}') == linux ]] || fail 'A reachable Linux Docker daemon is required.'
source "$ROOT/versions.lock.env"
[[ "$TAILSCALE_IMAGE" =~ ^ghcr.io/tailscale/tailscale:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[a-f0-9]{64}$ ]] || fail 'Invalid pinned Tailscale image.'

routes=()
declare -A seen_networks=()
for network in "${networks[@]}"; do
  [[ "$network" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || fail 'Use Docker network names, not IDs or special characters.'
  [[ -z ${seen_networks[$network]:-} ]] || fail "Duplicate network: $network"
  seen_networks[$network]=1
  [[ $(docker network inspect --format '{{.Name}}' "$network") == "$network" ]] || fail 'Specify the Docker network name, not its ID.'
  [[ $(docker network inspect --format '{{.Driver}}' "$network") == bridge ]] || fail "Expected an existing bridge network: $network"
  [[ $(docker network inspect --format '{{index .Options "com.docker.network.bridge.enable_icc"}}' "$network") != false ]] || fail "Inter-container connectivity is disabled on $network."
  subnets=$(docker network inspect --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' "$network")
  found=0
  while IFS= read -r subnet; do
    [[ -n "$subnet" && "$subnet" != *:* ]] || continue
    private_ipv4_subnet "$subnet" || fail "Expected a canonical private IPv4 subnet on $network: $subnet"
    routes+=("$subnet")
    found=1
  done <<< "$subnets"
  [[ "$found" == 1 ]] || fail "No private IPv4 subnet on $network."
done
[[ $(docker network inspect --format '{{.Internal}}' "${networks[0]}") == false ]] || fail 'The first network must permit outbound access to Tailscale.'
mapfile -t routes < <(printf '%s\n' "${routes[@]}" | sort -u)
routes_csv=$(IFS=,; printf '%s' "${routes[*]}")
networks_csv=$(IFS=,; printf '%s' "${networks[*]}")
role=orca-tailscale-gateway-v1
volume="$name-state"
existing=0 needs_key=1
if docker container inspect "$name" >/dev/null 2>&1; then
  existing=1
  needs_key=0
  [[ $(docker container inspect --format '{{index .Config.Labels "com.orca-deploy.role"}}' "$name") == "$role" ]] || fail "Container $name belongs to another deployment."
  [[ $(docker container inspect --format '{{.Config.Image}}' "$name") == "$TAILSCALE_IMAGE" &&
     $(docker container inspect --format '{{.HostConfig.NetworkMode}}' "$name") == "${networks[0]}" &&
     $(docker container inspect --format '{{index .Config.Labels "com.orca-deploy.networks"}}' "$name") == "$networks_csv" &&
     $(docker container inspect --format '{{index .Config.Labels "com.orca-deploy.routes"}}' "$name") == "$routes_csv" ]] ||
    fail 'Gateway image or network configuration changed. Follow the documented controlled recreation procedure.'
  if [[ $(docker container inspect --format '{{.State.Status}}' "$name") == created ]]; then needs_key=1; fi
fi
if docker volume inspect "$volume" >/dev/null 2>&1; then
  [[ $(docker volume inspect --format '{{index .Labels "com.orca-deploy.gateway"}}' "$volume") == "$name" ]] || fail "Volume $volume belongs to another deployment."
elif [[ "$existing" == 1 ]]; then
  fail 'Gateway state volume is missing. Inspect the deployment before continuing.'
fi
note "Gateway: $name"
note "Docker networks: $networks_csv"
note "Advertised IPv4 routes: $routes_csv"
note "Pinned image: $TAILSCALE_IMAGE"
note 'Uses userspace routing; no host networking, published ports, TUN devices or extra capabilities.'
if [[ "$dry_run" == 1 ]]; then
  note 'Dry run complete. No container, volume, credentials or network configuration was changed.'
  exit 0
fi

data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/orca-gateway/$name"
[[ "$data_dir" == /* && ! -L "$data_dir" ]] || fail 'Use an absolute, nonsymlink XDG_DATA_HOME.'
data_dir=$(readlink -m -- "$data_dir")
[[ "$data_dir" != "$ROOT/"* ]] || fail 'Keep gateway credentials outside this repository.'
mkdir -p "$data_dir"
[[ -O "$data_dir" ]] || fail 'Gateway credential directory belongs to another user.'
chmod 700 "$data_dir"
exec 8>"$data_dir/install.lock"
flock -n 8 || fail 'Another gateway installation is in progress.'
if [[ "$existing" == 1 ]]; then
  [[ $(docker container inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/tailscale"}}{{.Name}}{{end}}{{end}}' "$name") == "$volume" ]] || fail 'Existing gateway has an unexpected state volume.'
fi
if [[ "$needs_key" == 1 ]]; then
  auth_file=${auth_file:-$data_dir/bootstrap.authkey}
  if [[ ! -e "$auth_file" ]]; then
    [[ "$auth_file" == "$data_dir/bootstrap.authkey" && -t 0 ]] || fail 'First installation needs --auth-key-file, or an interactive terminal for hidden input.'
    read -r -s -p 'Tailscale non-ephemeral auth key (hidden): ' auth_key
    printf '\n' >&2
    [[ "$auth_key" == tskey-auth-* && "$auth_key" != *[[:space:]]* ]] || fail 'Expected a Tailscale auth key.'
    printf '%s\n' "$auth_key" > "$auth_file"
    unset auth_key
  fi
  [[ -s "$auth_file" ]] || fail 'The initial auth-key file is empty.'
  auth_file=$(readlink -f -- "$auth_file")
  [[ -f "$auth_file" && -r "$auth_file" && -O "$auth_file" ]] || fail 'The auth-key file must exist and belong to the current user.'
  [[ "$auth_file" != "$ROOT/"* ]] || fail 'Keep the auth-key file outside this repository.'
  mode=$(stat -c %a "$auth_file")
  (( (8#$mode & 077) == 0 )) || fail 'Restrict the auth-key file permissions to 600 or 400.'
elif [[ -n "$auth_file" ]]; then
  note 'Existing gateway keeps its saved credentials; the supplied bootstrap file is not reused.'
fi

if [[ "$existing" == 0 ]]; then
  docker pull "$TAILSCALE_IMAGE"
  docker volume create --label "com.orca-deploy.gateway=$name" "$volume" >/dev/null
  docker create --name "$name" --hostname "$name" --restart unless-stopped \
    --network "${networks[0]}" --cap-drop ALL --security-opt no-new-privileges:true \
    --label "com.orca-deploy.role=$role" \
    --label "com.orca-deploy.networks=$networks_csv" --label "com.orca-deploy.routes=$routes_csv" \
    --mount "type=volume,src=$volume,dst=/var/lib/tailscale" \
    --env TS_USERSPACE=true --env TS_AUTH_ONCE=true --env TS_ACCEPT_DNS=false \
    --env TS_STATE_DIR=/var/lib/tailscale --env "TS_HOSTNAME=$name" \
    --env TS_AUTHKEY=file:/var/lib/tailscale/bootstrap.authkey --env "TS_ROUTES=$routes_csv" \
    --env TS_EXTRA_ARGS=--accept-routes=false \
    --env TS_ENABLE_HEALTH_CHECK=true --env TS_LOCAL_ADDR_PORT=127.0.0.1:9002 \
    --health-cmd 'wget -q -T 3 -O /dev/null http://127.0.0.1:9002/healthz' \
    --health-interval 5s --health-timeout 4s --health-retries 3 --health-start-period 20s \
    --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
    "$TAILSCALE_IMAGE" >/dev/null
fi
if [[ "$needs_key" == 1 ]]; then
  # Docker copies with container-root ownership, so a capability-free process can read mode 600.
  docker cp "$auth_file" "$name:/var/lib/tailscale/bootstrap.authkey"
fi
attached=$(docker container inspect --format '{{range $network, $settings := .NetworkSettings.Networks}}{{println $network}}{{end}}' "$name")
while IFS= read -r network; do
  [[ -z "$network" || -n ${seen_networks[$network]:-} ]] || fail "Gateway has an unexpected network: $network"
done <<< "$attached"
if [[ $(docker container inspect --format '{{.State.Running}}' "$name") != true ]]; then
  docker start "$name" >/dev/null
fi
for network in "${networks[@]}"; do
  if [[ $'\n'"$attached"$'\n' != *$'\n'"$network"$'\n'* ]]; then
    docker network connect "$network" "$name"
  fi
done

deadline=$((SECONDS + wait_seconds))
while (( SECONDS < deadline )); do
  state=$(docker container inspect --format '{{.State.Status}}' "$name")
  [[ "$state" == running ]] || fail "Gateway state is $state. Inspect: docker logs $name"
  health=$(docker container inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name")
  if [[ "$health" == healthy ]]; then
    gateway_ip=$(docker exec "$name" tailscale ip -4)
    note "Gateway enrolled; local health check passed. Tailscale IP: $gateway_ip"
    note 'Next: restrict tailnet access to the Orca ports, approve the advertised routes, and test TCP from Windows.'
    note 'Route approval and end-to-end Windows connectivity are not checked by this installer.'
    exit 0
  fi
  [[ "$health" != unhealthy ]] || fail "Gateway health check failed. Inspect: docker logs $name"
  sleep 1
done
fail "Gateway startup timed out. State and credentials were retained. Inspect: docker logs $name"
