#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/linux/common.sh"

usage() {
  printf '%s\n' \
    'Usage: bash hub/sync-windows.sh [options]' \
    'Run on the Docker host. Mints gateway pairing offers for active Windows clients' \
    'across already-enrolled containers recorded by hub/connect.sh.' \
    '  --hub NAME        Hub container (default: orca-hub)' \
    '  --client NAME     Limit provisioning to one active Windows client' \
    '  --node NAME       Limit provisioning to one enrolled node' \
    '  --reprovision     Re-mint offers even for clients that already hold grants' \
    '  --dry-run         Show what would be provisioned without minting offers'
}

hub=orca-hub filter_client='' filter_node='' reprovision=0 dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hub|--client|--node)
      [[ $# -ge 2 && -n "$2" ]] || fail "Missing value for $1"
      case "$1" in
        --hub) hub=$2 ;; --client) filter_client=$2 ;; --node) filter_node=$2 ;;
      esac
      shift 2 ;;
    --reprovision) reprovision=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

[[ "$hub" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || fail 'Specify a valid hub container name.'
if [[ -n "$filter_client" ]]; then
  [[ "$filter_client" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$ ]] || fail 'Invalid client name.'
fi
if [[ -n "$filter_node" ]]; then
  [[ "$filter_node" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$ && "${filter_node,,}" != local ]] || fail 'Invalid node name.'
fi

require_commands docker
if [[ -n ${DOCKER_CONTEXT:-} || -z ${DOCKER_HOST:-} ]]; then
  endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}')
else endpoint=$DOCKER_HOST; fi
[[ "$endpoint" == unix://* ]] || fail 'Run on the Docker host using its local Unix socket.'
[[ $(docker container inspect --format '{{index .Config.Labels "com.orca-deploy.role"}}' "$hub") == orca-mobile-hub-v1 ]] || fail 'The selected container is not an orca-deploy hub.'
gateway=$(docker container inspect --format '{{index .Config.Labels "com.orca-deploy.gateway"}}' "$hub")
docker exec "$hub" hubctl health || fail 'The hub is not ready. Run hub/install.sh first.'

active_clients=$(docker exec "$hub" hubctl client list --active-names)
if [[ -z "$active_clients" ]]; then
  fail 'No active Windows clients exist. Run: docker exec orca-hub hubctl client add <name>'
fi
clients=()
while IFS= read -r c; do
  [[ -n "$c" ]] || continue
  if [[ -z "$filter_client" || "$filter_client" == "$c" ]]; then clients+=("$c"); fi
done <<< "$active_clients"
[[ ${#clients[@]} -gt 0 ]] || fail "Windows client '$filter_client' is not active."

meta_dir="${XDG_DATA_HOME:-$HOME/.local/share}/orca-gateway/$gateway/nodes"
if [[ ! -d "$meta_dir" ]]; then
  fail "No recorded nodes found at $meta_dir. Re-run hub/connect.sh for existing containers first."
fi

provisioned=0 skipped=0 failed=0
shopt -s nullglob
meta_files=("$meta_dir"/*.env)
shopt -u nullglob
[[ ${#meta_files[@]} -gt 0 ]] || fail "No recorded nodes found in $meta_dir."

for meta_file in "${meta_files[@]}"; do
  [[ -O "$meta_file" ]] || fail "Refusing metadata file owned by another user: $meta_file"
  NODE_NAME='' NODE_CONTAINER='' NODE_USER='' NODE_PREFIX='' NODE_PORT='' NODE_HUB=''
  # shellcheck source=/dev/null
  source "$meta_file"
  [[ -n "$NODE_NAME" && -n "$NODE_CONTAINER" && -n "$NODE_USER" && -n "$NODE_PREFIX" ]] || continue
  if [[ -n "$filter_node" && "$filter_node" != "$NODE_NAME" ]]; then continue; fi
  if [[ -n "$NODE_HUB" && "$NODE_HUB" != "$hub" ]]; then continue; fi

  # Skip nodes that were removed from the hub.
  if ! desktop_ep=$(docker exec "$hub" hubctl desktop-endpoint "$NODE_NAME" 2>/dev/null); then
    continue
  fi
  rc=0
  docker exec "$hub" hubctl offer-needed "${clients[0]}" "$NODE_NAME" >/dev/null 2>&1 || rc=$?
  if (( rc != 0 && rc != 3 )); then
    note "Skipping '$NODE_NAME': not currently registered in $hub."
    skipped=$((skipped + 1))
    continue
  fi

  if [[ $(docker container inspect --format '{{.State.Running}}' "$NODE_CONTAINER" 2>/dev/null || printf false) != true ]]; then
    note "Skipping '$NODE_NAME': container '$NODE_CONTAINER' is not running."
    skipped=$((skipped + 1))
    continue
  fi
  home=$(docker exec --user "$NODE_USER" "$NODE_CONTAINER" sh -c 'getent passwd "$(id -u)" | cut -d: -f6')
  run=(docker exec --user "$NODE_USER" --env "HOME=$home" "$NODE_CONTAINER")

  for client in "${clients[@]}"; do
    need=0
    if [[ "$reprovision" == 1 ]]; then
      need=1
    elif docker exec "$hub" hubctl offer-needed "$client" "$NODE_NAME" >/dev/null 2>&1; then
      need=1
    fi
    if [[ "$need" == 0 ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    if [[ "$dry_run" == 1 ]]; then
      note "[dry-run] Would provision '$client' -> '$NODE_NAME' ($desktop_ep)"
      provisioned=$((provisioned + 1))
      continue
    fi
    if "${run[@]}" "$NODE_PREFIX/bin/orca-service" cli pair --address "$desktop_ep" --json |
      docker exec -i "$hub" hubctl offer-put "$client" "$NODE_NAME" >/dev/null; then
      note "Provisioned '$client' -> '$NODE_NAME'"
      provisioned=$((provisioned + 1))
    else
      note "WARNING: failed to provision '$client' -> '$NODE_NAME'"
      failed=$((failed + 1))
    fi
  done
done

note "Summary: provisioned=$provisioned skipped=$skipped failed=$failed"
(( failed == 0 ))
