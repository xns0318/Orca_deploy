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
  fingerprint=$(cd "$ROOT" && sha256sum versions.lock.env hub/Dockerfile hub/.dockerignore hub/entrypoint.sh hub/hubctl hub/hubctl.cjs hub/orca-api.cjs hub/monitor.cjs hub/image.sh | sha256sum)
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
    fail 'Hub image build failed. For a host without registry access, use hub/export-image.sh on a connected builder, then install with --image-archive FILE. Gateway and hub state were kept.'
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
