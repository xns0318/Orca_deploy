#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/linux/common.sh"
source "$ROOT/versions.lock.env"
source "$ROOT/hub/image.sh"
output='' build_network=default image=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|--build-network)
      [[ $# -ge 2 && -n "$2" ]] || fail "Missing value for $1"
      case "$1" in --output) output=$2 ;; --build-network) build_network=$2 ;; esac
      shift 2 ;;
    --help|-h)
      printf '%s\n' 'Usage: bash hub/export-image.sh --output /path/orca-hub.tar.gz [--build-network default|host]'
      printf '%s\n' 'Build on an internet-connected Docker host of the target architecture; export image and SHA256.'
      exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done
[[ -n "$output" ]] || fail '--output is required.'
[[ "$build_network" == default || "$build_network" == host ]] || fail 'Build network must be default or host.'
require_commands docker sha256sum gzip mktemp
[[ ! -e "$output" && ! -L "$output" && ! -e "$output.sha256" && ! -L "$output.sha256" ]] || fail 'Output already exists; choose a new path.'
[[ -d $(dirname -- "$output") ]] || fail 'Create the output directory first.'
hub_image_init
note "Hub image: $image"
if ! docker image inspect "$image" >/dev/null 2>&1; then hub_image_build "$build_network"; fi
hub_image_verify
temp=$(mktemp -- "$output.tmp.XXXXXX")
trap 'rm -f -- "$temp" "$temp.sha256"' EXIT
docker image save "$image" | gzip -1 > "$temp"
checksum=$(sha256sum -- "$temp")
printf '%s  %s\n' "${checksum%% *}" "$(basename -- "$output")" > "$temp.sha256"
mv -- "$temp" "$output"
mv -- "$temp.sha256" "$output.sha256"
note "Exported: $output"
note "Checksum: $output.sha256"
note 'Transfer both files and the same repository revision to the target host.'
