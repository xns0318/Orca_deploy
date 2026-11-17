#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/linux/common.sh"
source "$ROOT/linux/network.sh"
usage() {
  printf '%s\n' \
    'Usage: bash hub/connect.sh --container NAME --name LABEL [options]' \
    'Run on the Docker host. Install Orca in an existing container and register it with the hub.' \
    '  --hub NAME        Hub container (default: orca-hub)' \
    '  --user USER       Existing agent CLI user inside the container (default: root)' \
    '  --prefix PATH     Existing/custom Orca install directory' \
    '  --network NAME    Choose when multiple networks are shared with the gateway' \
    '  --port PORT       First-install port (default: 6768); existing config is preserved' \
    '  --dry-run         Inspect only; no installs, offers or registrations'
}
container='' name='' hub=orca-hub user=root prefix='' network='' port=6768 dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --container|--name|--hub|--user|--prefix|--network|--port)
      [[ $# -ge 2 && -n "$2" ]] || fail "Missing value for $1"
      case "$1" in
        --container) container=$2 ;; --name) name=$2 ;; --hub) hub=$2 ;;
        --user) user=$2 ;; --prefix) prefix=$2 ;; --network) network=$2 ;; --port) port=$2 ;;
      esac
      shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done
[[ "$container" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ && "$hub" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || fail 'Specify valid container and hub names.'
[[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$ && "${name,,}" != local ]] || fail 'Use a unique node label other than local.'
[[ "$user" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_-]*$ ]] || fail 'Specify an existing username or numeric UID.'
[[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) || fail 'Invalid port.'
require_commands docker tar
if [[ -n ${DOCKER_CONTEXT:-} || -z ${DOCKER_HOST:-} ]]; then
  endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}')
else endpoint=$DOCKER_HOST; fi
[[ "$endpoint" == unix://* ]] || fail 'Run on the Docker host using its local Unix socket.'
[[ $(docker container inspect --format '{{index .Config.Labels "com.orca-deploy.role"}}' "$hub") == orca-mobile-hub-v1 ]] || fail 'The selected container is not an orca-deploy hub.'
gateway=$(docker container inspect --format '{{index .Config.Labels "com.orca-deploy.gateway"}}' "$hub")
target_id=$(docker container inspect --format '{{.Id}}' "$container")
[[ "$target_id" != "$(docker container inspect --format '{{.Id}}' "$hub")" &&
   "$target_id" != "$(docker container inspect --format '{{.Id}}' "$gateway")" ]] || fail 'The target must be an agent container, not the hub or gateway.'
[[ $(docker container inspect --format '{{.State.Running}}' "$container") == true ]] || fail 'Start the existing agent container first.'
shared=()
gateway_networks=$(docker container inspect --format '{{range $n, $v := .NetworkSettings.Networks}}{{println $n}}{{end}}' "$gateway")
target_networks=$(docker container inspect --format '{{range $n, $v := .NetworkSettings.Networks}}{{printf "%s %s\n" $n $v.IPAddress}}{{end}}' "$container")
while read -r candidate ip; do
  [[ -n "$candidate" && -n "$ip" ]] || continue
  [[ -z "$network" || "$network" == "$candidate" ]] || continue
  if [[ $'\n'"$gateway_networks"$'\n' == *$'\n'"$candidate"$'\n'* ]]; then
    private_ipv4_subnet "$ip/32" || fail 'Expected a private IPv4 container address.'
    shared+=("$ip")
  fi
done <<< "$target_networks"
[[ ${#shared[@]} == 1 ]] || fail 'Select exactly one shared gateway/agent bridge network using --network.'
home=$(docker exec --user "$user" "$container" sh -c 'getent passwd "$(id -u)" | cut -d: -f6')
[[ "$home" == /* && "$home" != *$'\n'* ]] || fail 'The agent user needs an existing passwd entry with an absolute HOME.'
prefix=${prefix:-$home/.local/share/orca-deploy}
[[ "$prefix" == /* && "$prefix" != / && "$prefix" != "$home" && "$prefix" != *$'\n'* ]] || fail 'Use a dedicated absolute prefix.'
run=(docker exec --user "$user" --env "HOME=$home" "$container")
if "${run[@]}" test -f "$prefix/.orca-deploy"; then
  port=$("${run[@]}" bash -c 'source "$1/config.env"; printf "%s" "$LISTEN_PORT"' bash "$prefix")
fi
[[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) || fail 'Invalid saved listen port.'
address="ws://${shared[0]}:$port"
note "Agent container: $container; user: $user; hub name: $name; endpoint: $address"
if [[ "$dry_run" == 1 ]]; then note 'Dry run complete. Nothing changed.'; exit 0; fi
docker exec "$hub" hubctl health || fail 'The hub is not ready. Run hub/install.sh first.'
stage=$("${run[@]}" mktemp -d /tmp/orca-enroll.XXXXXX)
[[ "$stage" == /tmp/orca-enroll.* && "$stage" != *$'\n'* ]] || fail 'Invalid staging directory.'
trap '"${run[@]}" rm -rf -- "$stage" >/dev/null 2>&1 || true' EXIT
tar -cf - -C "$ROOT" install.sh linux versions.lock.env |
  docker exec -i --user "$user" --env "HOME=$home" "$container" tar -xf - -C "$stage"
# Existing nodes keep their original name, identity, advertised address and running sessions.
"${run[@]}" bash -c '
  if [[ -f "$2/.orca-deploy" ]]; then
    bash "$1/install.sh" --prefix "$2" --no-pair
  else
    bash "$1/install.sh" --prefix "$2" --name "$3" --address "$4" --port "$5" --no-pair
  fi
' bash "$stage" "$prefix" "$name" "$address" "$port"
if docker exec "$hub" hubctl probe "$name" "$address" >/dev/null 2>&1; then
  note 'Already enrolled and reachable. Saved grants and phone pairing were kept.'
  exit 0
fi
# The one-time access link flows only over Docker stdin, never argv, disk or logs.
"${run[@]}" "$prefix/bin/orca-service" cli pair --address "$address" --json |
  docker exec -i "$hub" hubctl register "$name"
note 'Container enrolled. The phone keeps its existing central pairing.'
note 'After an agent-container restart, rerun this command or use its existing Orca startup hook.'
