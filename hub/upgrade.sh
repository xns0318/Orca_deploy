#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/linux/common.sh"
source "$ROOT/versions.lock.env"

usage() {
  printf '%s\n' \
    'Usage: bash hub/upgrade.sh [options]' \
    'Run on the Docker host. Upgrades orca-hub (without Docker Hub) and all enrolled agent containers' \
    'to the ORCA_VERSION pinned in versions.lock.env, reusing a single downloaded server tarball.' \
    '  --hub NAME              Hub container (default: orca-hub)' \
    '  --network NAME          Gateway bridge network (default: read from existing gateway)' \
    '  --hub-deb FILE          Pre-downloaded official orca-ide_<ver>_<arch>.deb for offline hub upgrade' \
    '  --server-archive FILE   Pre-downloaded official orca-server-linux-<arch>.tar.gz (reused for all nodes)' \
    '  --node NAME             Upgrade only this enrolled node' \
    '  --hub-only              Upgrade only the hub container' \
    '  --nodes-only            Upgrade only enrolled agent containers' \
    '  --dry-run               Show the upgrade plan without making changes'
}

hub=orca-hub hub_deb='' server_archive='' filter_node='' hub_only=0 nodes_only=0 dry_run=0
networks=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hub|--network|--hub-deb|--server-archive|--node)
      [[ $# -ge 2 && -n "$2" ]] || fail "Missing value for $1"
      case "$1" in
        --hub) hub=$2 ;;
        --network) networks+=("$2") ;;
        --hub-deb) hub_deb=$2 ;;
        --server-archive) server_archive=$2 ;;
        --node) filter_node=$2 ;;
      esac
      shift 2 ;;
    --hub-only) hub_only=1; shift ;;
    --nodes-only) nodes_only=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

[[ "$hub_only" != 1 || "$nodes_only" != 1 ]] || fail 'Specify at most one of --hub-only or --nodes-only.'
[[ "$hub" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || fail 'Specify a valid hub container name.'
if [[ -n "$filter_node" ]]; then
  [[ "$filter_node" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$ && "${filter_node,,}" != local ]] || fail 'Invalid node name.'
fi
require_commands docker tar sha256sum mktemp
if [[ -n ${DOCKER_CONTEXT:-} || -z ${DOCKER_HOST:-} ]]; then
  endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}')
else endpoint=$DOCKER_HOST; fi
[[ "$endpoint" == unix://* ]] || fail 'Run on the Docker host using its local Unix socket.'
[[ $(docker container inspect --format '{{index .Config.Labels "com.orca-deploy.role"}}' "$hub") == orca-mobile-hub-v1 ]] ||
  fail 'The selected container is not an orca-deploy hub.'
gateway=$(docker container inspect --format '{{index .Config.Labels "com.orca-deploy.gateway"}}' "$hub")
if [[ ${#networks[@]} -eq 0 ]]; then
  nets_csv=$(docker container inspect --format '{{index .Config.Labels "com.orca-deploy.networks"}}' "$gateway")
  IFS=, read -r -a networks <<< "$nets_csv"
fi
[[ ${#networks[@]} -gt 0 ]] || fail 'Could not detect gateway networks. Pass --network NAME.'

arch=$(docker version --format '{{.Server.Arch}}')
case "$arch" in
  amd64|x86_64) server_arch=x64; server_url=$LINUX_X64_URL; server_sha=$LINUX_X64_SHA256 ;;
  arm64|aarch64) server_arch=arm64; server_url=$LINUX_ARM64_URL; server_sha=$LINUX_ARM64_SHA256 ;;
  *) fail 'Unsupported Docker host architecture.' ;;
esac

note "Target Orca version: $ORCA_VERSION ($server_arch); hub: $hub; gateway: $gateway"

# Step 1: Upgrade orca-hub without Docker Hub (preserving orca-hub-home volume & all pairings).
if [[ "$nodes_only" == 0 ]]; then
  hub_cmd=(bash "$ROOT/hub/install.sh" --name "$hub" --gateway-name "$gateway" --recreate --reuse-local-base)
  for n in "${networks[@]}"; do hub_cmd+=(--network "$n"); done
  if [[ -n "$hub_deb" ]]; then hub_cmd+=(--hub-deb "$hub_deb"); fi
  if [[ "$dry_run" == 1 ]]; then
    note "[dry-run] Would upgrade hub '$hub' to $ORCA_VERSION using local base image${hub_deb:+ + $hub_deb}."
    hub_cmd+=(--dry-run)
  fi
  "${hub_cmd[@]}"
fi

if [[ "$hub_only" == 1 ]]; then
  note "Hub-only upgrade complete ($ORCA_VERSION)."
  exit 0
fi

# Step 2: Upgrade enrolled agent containers recorded by hub/connect.sh, downloading the server tarball at most once.
meta_dir="${XDG_DATA_HOME:-$HOME/.local/share}/orca-gateway/$gateway/nodes"
if [[ ! -d "$meta_dir" ]]; then
  fail "No recorded nodes found at $meta_dir. Run hub/connect.sh for existing containers first."
fi
shopt -s nullglob
meta_files=("$meta_dir"/*.env)
shopt -u nullglob
[[ ${#meta_files[@]} -gt 0 ]] || fail "No recorded nodes found in $meta_dir."

tmp_cache=''
cleanup() {
  if [[ -n "$tmp_cache" ]]; then rm -rf -- "$tmp_cache"; fi
}
trap cleanup EXIT

cached_archive=''
ensure_server_archive() {
  if [[ -n "$cached_archive" ]]; then return 0; fi
  if [[ -n "$server_archive" ]]; then
    [[ -f "$server_archive" && -r "$server_archive" ]] || fail "Server archive is not readable: $server_archive"
    local actual
    actual=$(sha256sum -- "$server_archive")
    [[ "${actual%% *}" == "$server_sha" ]] || fail 'Server archive SHA256 mismatch. Aborting node upgrades.'
    cached_archive=$server_archive
    note "Verified pre-downloaded server archive: $cached_archive"
    return 0
  fi
  require_commands curl
  tmp_cache=$(mktemp -d)
  cached_archive="$tmp_cache/orca-server-linux-$server_arch.tar.gz"
  note "Downloading Orca server $ORCA_VERSION ($server_arch) once on host for all containers..."
  curl --fail --show-error --location --retry 3 --connect-timeout 15 --max-time 600 \
    --proto '=https' --proto-redir '=https' "$server_url" -o "$cached_archive"
  local actual
  actual=$(sha256sum -- "$cached_archive")
  [[ "${actual%% *}" == "$server_sha" ]] || fail 'Downloaded server archive SHA256 mismatch. Aborting node upgrades.'
}

upgraded=0 skipped=0 failed=0
for meta_file in "${meta_files[@]}"; do
  [[ -O "$meta_file" ]] || fail "Refusing metadata file owned by another user: $meta_file"
  NODE_NAME='' NODE_CONTAINER='' NODE_USER='' NODE_PREFIX='' NODE_PORT='' NODE_HUB=''
  # shellcheck source=/dev/null
  source "$meta_file"
  [[ -n "$NODE_NAME" && -n "$NODE_CONTAINER" && -n "$NODE_USER" && -n "$NODE_PREFIX" ]] || continue
  if [[ -n "$filter_node" && "$filter_node" != "$NODE_NAME" ]]; then continue; fi
  if [[ -n "$NODE_HUB" && "$NODE_HUB" != "$hub" ]]; then continue; fi

  if [[ $(docker container inspect --format '{{.State.Running}}' "$NODE_CONTAINER" 2>/dev/null || printf false) != true ]]; then
    note "Skipping '$NODE_NAME': container '$NODE_CONTAINER' is not running."
    skipped=$((skipped + 1))
    continue
  fi
  home=$(docker exec --user "$NODE_USER" "$NODE_CONTAINER" sh -c 'getent passwd "$(id -u)" | cut -d: -f6')
  run=(docker exec --user "$NODE_USER" --env "HOME=$home" "$NODE_CONTAINER")
  current_ver=$("${run[@]}" bash -c 'awk "\$1==\"orca\"{print \$2}" "$1/current/VERSION" 2>/dev/null || true' bash "$NODE_PREFIX")
  if [[ "$current_ver" == "$ORCA_VERSION" ]]; then
    note "Node '$NODE_NAME' ($NODE_CONTAINER, user=$NODE_USER) is already on Orca $ORCA_VERSION; skipping."
    skipped=$((skipped + 1))
    continue
  fi
  if [[ "$dry_run" == 1 ]]; then
    note "[dry-run] Would upgrade node '$NODE_NAME' ($NODE_CONTAINER, user=$NODE_USER) from ${current_ver:-unknown} to $ORCA_VERSION."
    upgraded=$((upgraded + 1))
    continue
  fi

  ensure_server_archive
  note "Upgrading node '$NODE_NAME' ($NODE_CONTAINER, user=$NODE_USER): ${current_ver:-unknown} -> $ORCA_VERSION..."
  stage=$("${run[@]}" mktemp -d /tmp/orca-upgrade.XXXXXX)
  if (
    trap '"${run[@]}" rm -rf -- "$stage" >/dev/null 2>&1 || true' EXIT
    tar -cf - -C "$ROOT" install.sh linux versions.lock.env |
      docker exec -i --user "$NODE_USER" --env "HOME=$home" "$NODE_CONTAINER" tar -xf - -C "$stage"
    docker exec -i --user "$NODE_USER" --env "HOME=$home" "$NODE_CONTAINER" \
      sh -c 'cat > "$1/server.tar.gz"' sh "$stage" < "$cached_archive"
    "${run[@]}" bash "$stage/install.sh" --prefix "$NODE_PREFIX" --archive "$stage/server.tar.gz" --upgrade --no-pair
  ); then
    note "Upgraded node '$NODE_NAME' to Orca $ORCA_VERSION (existing projects and pairings preserved)."
    upgraded=$((upgraded + 1))
  else
    note "WARNING: failed to upgrade node '$NODE_NAME'."
    failed=$((failed + 1))
  fi
done

note "Upgrade summary (target $ORCA_VERSION): upgraded=$upgraded skipped=$skipped failed=$failed"
(( failed == 0 ))
