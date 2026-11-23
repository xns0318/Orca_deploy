#!/usr/bin/env bash

hub_image_init() {
  [[ $(docker version --format '{{.Server.Os}}') == linux ]] || fail 'The hub requires a Linux Docker daemon.'
  arch=$(docker version --format '{{.Server.Arch}}')
  case "$arch" in
    amd64|x86_64) arch=amd64; url=$HUB_X64_URL; digest=$HUB_X64_SHA256 ;;
    arm64|aarch64) arch=arm64; url=$HUB_ARM64_URL; digest=$HUB_ARM64_SHA256 ;;
    *) fail 'The hub supports Linux amd64 and arm64.' ;;
  esac
  [[ "$digest" =~ ^[a-f0-9]{64}$ && "$url" == https://github.com/stablyai/orca/releases/download/* ]] || fail 'Invalid hub release lock.'
  [[ "$HUB_BASE_IMAGE" =~ ^debian:bookworm-slim@sha256:[a-f0-9]{64}$ ]] || fail 'Invalid base image lock.'
  fingerprint=$(cd "$ROOT" && sha256sum versions.lock.env hub/Dockerfile hub/Dockerfile.overlay hub/Dockerfile.upgrade hub/.dockerignore hub/entrypoint.sh hub/hubctl hub/hubctl.cjs hub/orca-api.cjs hub/monitor.cjs hub/bridge-store.cjs hub/gateway-bridge.cjs hub/image.sh | sha256sum)
  fingerprint=${fingerprint%% *}
  image="orca-deploy-hub:$ORCA_VERSION-$arch-${fingerprint:0:16}"
}

hub_image_build() {
  docker build --network "${1:-default}" \
    --build-arg HTTP_PROXY --build-arg HTTPS_PROXY --build-arg NO_PROXY \
    --build-arg http_proxy --build-arg https_proxy --build-arg no_proxy \
    --build-arg "BASE_IMAGE=$HUB_BASE_IMAGE" --build-arg "ORCA_VERSION=$ORCA_VERSION" \
    --build-arg "ORCA_DEB_URL=$url" --build-arg "ORCA_DEB_SHA256=$digest" \
    --label "com.orca-deploy.fingerprint=$fingerprint" --tag "$image" "$ROOT/hub" ||
    fail 'Hub image build failed. For a host without registry access, use --reuse-local-base (if an earlier matching Orca hub image is already loaded) or hub/export-image.sh on a connected builder with --image-archive FILE. Gateway and hub state were kept.'
}

hub_find_local_base_image() {
  local preferred=${1:-} allow_any_version=${2:-0} candidate meta
  local exact_prefix="orca-deploy-hub:$ORCA_VERSION-$arch-"
  local any_pattern="^orca-deploy-hub:[0-9]+\.[0-9]+\.[0-9]+-${arch}-[a-f0-9]{16}$"
  local -a candidates=()
  if [[ -n "$preferred" && "$preferred" != "$image" ]]; then
    if [[ "$preferred" == "$exact_prefix"* || ( "$allow_any_version" == 1 && "$preferred" =~ $any_pattern ) ]]; then
      candidates+=("$preferred")
    fi
  fi
  while IFS= read -r candidate; do
    [[ -n "$candidate" && "$candidate" == "$exact_prefix"* && "$candidate" != "$image" ]] || continue
    candidates+=("$candidate")
  done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' "${exact_prefix}*" 2>/dev/null || true)
  if [[ "$allow_any_version" == 1 ]]; then
    while IFS= read -r candidate; do
      [[ -n "$candidate" && "$candidate" != "$image" && "$candidate" =~ $any_pattern ]] || continue
      candidates+=("$candidate")
    done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' "orca-deploy-hub:*" 2>/dev/null || true)
  fi
  for candidate in "${candidates[@]}"; do
    meta=$(docker image inspect --format '{{.Os}} {{.Architecture}} {{index .Config.Labels "com.orca-deploy.fingerprint"}}' "$candidate" 2>/dev/null || true)
    if [[ "$meta" =~ ^linux\ ${arch}\ [a-f0-9]{64}$ ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

hub_image_build_overlay() {
  local base_image=$1
  [[ "$base_image" == "orca-deploy-hub:$ORCA_VERSION-$arch-"* ]] || fail "Base hub image must match orca-deploy-hub:$ORCA_VERSION-$arch-*"
  note "Building hub script update offline from local base image: $base_image"
  docker build --network none -f "$ROOT/hub/Dockerfile.overlay" \
    --build-arg "BASE_HUB_IMAGE=$base_image" \
    --label "com.orca-deploy.fingerprint=$fingerprint" --tag "$image" "$ROOT/hub" ||
    fail 'Offline overlay hub build failed. Gateway and hub state were kept.'
}

hub_image_build_upgrade() {
  local base_image=$1 hub_deb=${2:-} ctx actual network_mode=default
  local -a build_args=(
    --build-arg "BASE_HUB_IMAGE=$base_image"
    --build-arg "ORCA_VERSION=$ORCA_VERSION"
    --build-arg "ORCA_DEB_URL=$url"
    --build-arg "ORCA_DEB_SHA256=$digest"
  )
  ctx=$(mktemp -d)
  # Clean staging context even on failure without clobbering caller traps.
  if ! (
    trap 'rm -rf -- "$ctx"' EXIT
    cp -- "$ROOT/hub/Dockerfile.upgrade" "$ROOT/hub/entrypoint.sh" "$ROOT/hub/hubctl" \
      "$ROOT/hub/hubctl.cjs" "$ROOT/hub/orca-api.cjs" "$ROOT/hub/monitor.cjs" \
      "$ROOT/hub/bridge-store.cjs" "$ROOT/hub/gateway-bridge.cjs" "$ctx/"
    if [[ -n "$hub_deb" ]]; then
      [[ -f "$hub_deb" && -r "$hub_deb" ]] || fail "Hub .deb file is not readable: $hub_deb"
      actual=$(sha256sum -- "$hub_deb")
      [[ "${actual%% *}" == "$digest" ]] || fail 'Hub .deb SHA256 mismatch. Nothing was built.'
      ln "$hub_deb" "$ctx/orca.deb" 2>/dev/null || cp -- "$hub_deb" "$ctx/orca.deb"
      network_mode=none
      build_args+=(--build-arg "ORCA_DEB_LOCAL=orca.deb")
      note "Upgrading hub offline to Orca $ORCA_VERSION from local base $base_image + verified .deb"
    else
      build_args+=(
        --build-arg HTTP_PROXY --build-arg HTTPS_PROXY --build-arg NO_PROXY
        --build-arg http_proxy --build-arg https_proxy --build-arg no_proxy
      )
      note "Upgrading hub to Orca $ORCA_VERSION from local base $base_image (skipping Docker Hub)"
    fi
    docker build --network "$network_mode" -f "$ctx/Dockerfile.upgrade" \
      "${build_args[@]}" \
      --label "com.orca-deploy.fingerprint=$fingerprint" --tag "$image" "$ctx"
  ); then
    fail 'Local-base hub upgrade build failed. Gateway and hub state were kept.'
  fi
}

hub_image_verify() {
  local metadata
  metadata=$(docker image inspect --format '{{.Os}} {{.Architecture}} {{index .Config.Labels "com.orca-deploy.fingerprint"}}' "$image") ||
    fail 'Expected hub image is missing. Export the image from this same repository revision and architecture.'
  [[ "$metadata" == "linux $arch $fingerprint" ]] || fail 'Hub image platform or source fingerprint does not match this checkout.'
}

hub_archive_verify() {
  local archive=$1 expected=$2 actual
  local -a lines=()
  [[ -f "$archive" && -r "$archive" ]] || fail "Image archive is not readable: $archive"
  if [[ -z "$expected" ]]; then
    [[ -f "$archive.sha256" && -r "$archive.sha256" ]] || fail 'Provide the adjacent FILE.sha256 or --image-sha256 DIGEST.'
    mapfile -t lines < "$archive.sha256"
    [[ ${#lines[@]} == 1 ]] || fail 'Expected one SHA256 entry in the archive checksum file.'
    read -r expected _ <<< "${lines[0]}"
  fi
  [[ "$expected" =~ ^[a-f0-9]{64}$ ]] || fail 'Invalid image archive SHA256.'
  actual=$(sha256sum -- "$archive")
  [[ "${actual%% *}" == "$expected" ]] || fail 'Image archive checksum mismatch. Nothing was loaded.'
  note 'Image archive SHA256 verified.'
}
