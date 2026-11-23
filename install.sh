#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$ROOT/linux/common.sh"
source "$ROOT/linux/network.sh"

usage() {
  printf '%s\n' \
    'Usage: bash install.sh --address ws://REACHABLE_HOST:PORT [options]' \
    '  --address auto   Use the single private IPv4 address behind the shared gateway' \
    '  --name NAME      Display name (default: hostname)' \
    '  --port PORT      Container listen port (default: 6768)' \
    '  --prefix PATH    Private install/state directory (default: ~/.local/share/orca-deploy)' \
    '  --archive FILE   Use a pre-downloaded official orca-server tarball (SHA256 still verified)' \
    '  --upgrade        Stop a running older Orca server after verifying the new release and switch versions' \
    '  --no-start       Install only; do not start or create a pairing offer' \
    '  --no-pair        Start without creating an offer (central hub enrollment creates its own)' \
    '  --help           Show help' \
    'Run as the same user and HOME as your agent CLIs. Network setup stays outside this script.'
}

PREFIX=${ORCA_DEPLOY_PREFIX:-${XDG_DATA_HOME:-$HOME/.local/share}/orca-deploy}
requested_address='' requested_name='' requested_port='' local_archive='' upgrade=0 no_start=0 no_pair=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --address|--name|--port|--prefix|--archive)
      [[ $# -ge 2 && -n "$2" ]] || fail "Missing value for $1"
      case "$1" in
        --address) requested_address=$2 ;;
        --name) requested_name=$2 ;;
        --port) requested_port=$2 ;;
        --prefix) PREFIX=$2 ;;
        --archive) local_archive=$2 ;;
      esac
      shift 2 ;;
    --upgrade) upgrade=1; shift ;;
    --no-start) no_start=1; shift ;;
    --no-pair) no_pair=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

[[ $(uname -s) == Linux ]] || fail 'This installer targets Linux containers.'
require_commands curl tar sha256sum flock setsid timeout getconf readlink install mktemp hostname
glibc=$(getconf GNU_LIBC_VERSION 2>/dev/null) || fail 'glibc is required. Use Ubuntu/Debian; Alpine musl is unsupported.'
version=${glibc#glibc }
IFS=. read -r major minor _ <<< "$version"
[[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || fail 'Could not identify glibc.'
(( major > 2 || (major == 2 && minor >= 28) )) || fail 'glibc 2.28 or later is required.'
[[ "$PREFIX" == /* && "$PREFIX" != / && "$PREFIX" != "$HOME" ]] || fail '--prefix must be a dedicated absolute directory.'
[[ ! -L "$PREFIX" ]] || fail 'The installation prefix must not be a symlink.'
if [[ -d "$PREFIX" && ! -f "$PREFIX/.orca-deploy" ]]; then
  [[ -z $(ls -A -- "$PREFIX") ]] || fail 'Refusing a nonempty directory without an orca-deploy marker.'
fi
mkdir -p "$PREFIX"
PREFIX=$(cd -- "$PREFIX" && pwd -P)
[[ "$PREFIX" != / && "$PREFIX" != "$(cd -- "$HOME" && pwd -P)" ]] || fail 'Use a dedicated installation directory.'
[[ -O "$PREFIX" ]] || fail 'The installation directory belongs to another user.'
chmod 700 "$PREFIX"
touch "$PREFIX/.orca-deploy"
exec 8>"$PREFIX/install.lock"
flock -n 8 || fail 'Another installation is in progress.'

NODE_NAME=$(hostname)
LISTEN_PORT=6768
ADVERTISE_ADDRESS=
INSTANCE_ID=
if [[ -f "$PREFIX/config.env" ]]; then load_config; fi
NODE_NAME=${requested_name:-$NODE_NAME}
LISTEN_PORT=${requested_port:-$LISTEN_PORT}
ADVERTISE_ADDRESS=${requested_address:-$ADVERTISE_ADDRESS}
[[ "$NODE_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$ ]] || fail 'Use a node name of 1-63 letters, digits, dots, underscores or hyphens.'
[[ "$LISTEN_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( LISTEN_PORT <= 65535 )) || fail 'Invalid listen port.'
if [[ "$ADVERTISE_ADDRESS" == auto ]]; then
  private_address=$(auto_private_address) || fail 'Automatic address selection needs exactly one private IPv4 address. Supply an explicit --address.'
  ADVERTISE_ADDRESS="ws://$private_address:$LISTEN_PORT"
  note "Advertised address: $ADVERTISE_ADDRESS (requires an approved gateway route and access policy)."
fi
[[ -n "$ADVERTISE_ADDRESS" ]] || fail 'Supply --address with the endpoint Windows can reach, including the published port.'
[[ "$ADVERTISE_ADDRESS" =~ ^wss?://[^[:space:]]+$ ]] || fail 'Use a full ws://host:port or wss://host:port address.'

source "$ROOT/versions.lock.env"
[[ "$ORCA_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Invalid version lock.'
case "$(uname -m)" in
  x86_64) arch=x64; url=$LINUX_X64_URL; expected=$LINUX_X64_SHA256 ;;
  aarch64|arm64) arch=arm64; url=$LINUX_ARM64_URL; expected=$LINUX_ARM64_SHA256 ;;
  *) fail 'Supported architectures: x86_64 and aarch64.' ;;
esac
[[ "$url" == https://* && "$expected" =~ ^[a-f0-9]{64}$ ]] || fail 'Invalid release URL or SHA256 in the lock file.'

pending_upgrade_stop=0
if owned_server_running; then
  [[ -f "$PREFIX/config.env" ]] || fail 'A running process has no saved configuration.'
  old_address=$ADVERTISE_ADDRESS old_port=$LISTEN_PORT old_name=$NODE_NAME
  load_config
  [[ "$old_address" == "$ADVERTISE_ADDRESS" && "$old_port" == "$LISTEN_PORT" && "$old_name" == "$NODE_NAME" ]] ||
    fail 'Stop orca-service before changing its configuration.'
  current_version=$(server_release_version "$PREFIX/current/VERSION") || fail 'Installed server VERSION metadata is invalid.'
  if [[ "$current_version" != "$ORCA_VERSION" ]]; then
    if [[ "$upgrade" == 1 ]]; then
      pending_upgrade_stop=1
      note "Preparing upgrade from Orca $current_version to $ORCA_VERSION (existing server stays up until verified)."
    else
      fail 'Stop the server and back up its state before installing another version.'
    fi
  else
    note 'Existing server configuration is unchanged.'
  fi
fi

mkdir -p "$PREFIX/releases" "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/state" "$PREFIX/logs"
release="$PREFIX/releases/$ORCA_VERSION-linux-$arch"
temporary=$(mktemp -d "$PREFIX/.install.XXXXXX")
trap 'rm -rf -- "$temporary"' EXIT
if [[ ! -f "$release/.archive-sha256" || $(<"$release/.archive-sha256") != "$expected" ]]; then
  [[ ! -e "$release" ]] || fail 'Existing release has an unexpected checksum marker. Inspect it before retrying.'
  if [[ -n "$local_archive" ]]; then
    [[ -f "$local_archive" && -r "$local_archive" ]] || fail "Server archive is not readable: $local_archive"
    note "Verifying pre-downloaded Orca $ORCA_VERSION ($arch) archive..."
    cp -- "$local_archive" "$temporary/server.tar.gz"
  else
    note "Downloading Orca $ORCA_VERSION ($arch)..."
    curl --fail --show-error --location --retry 3 --connect-timeout 15 --max-time 600 \
      --proto '=https' --proto-redir '=https' "$url" -o "$temporary/server.tar.gz"
  fi
  actual=$(sha256sum "$temporary/server.tar.gz")
  [[ ${actual%% *} == "$expected" ]] || fail 'SHA256 mismatch. The download will not be unpacked or executed.'
  mkdir "$temporary/release"
  tar --extract --gzip --file "$temporary/server.tar.gz" --directory "$temporary/release" \
    --strip-components=1 --no-same-owner --no-same-permissions
  [[ -x "$temporary/release/bin/orca-ide" && -f "$temporary/release/VERSION" ]] || fail 'Invalid server archive.'
  archive_version=$(server_release_version "$temporary/release/VERSION") || fail 'Invalid server VERSION metadata: expected one orca X.Y.Z entry.'
  [[ "$archive_version" == "$ORCA_VERSION" ]] || fail "Archive version does not match the lock file: expected $ORCA_VERSION, found $archive_version."
  printf '%s\n' "$expected" > "$temporary/release/.archive-sha256"
  mv -- "$temporary/release" "$release"
fi

if [[ "$pending_upgrade_stop" == 1 ]]; then
  note "Stopping Orca $current_version before activating $ORCA_VERSION..."
  "$PREFIX/bin/orca-service" stop 8>&-
fi

ln -s "$release" "$temporary/current"
mv -Tf -- "$temporary/current" "$PREFIX/current"
bundle_node
"$NODE_BIN" "$ROOT/linux/rpc-result.mjs" address "$ADVERTISE_ADDRESS"
"$PREFIX/current/bin/orca-ide" --version >/dev/null
[[ -n "$INSTANCE_ID" ]] || INSTANCE_ID=$(< /proc/sys/kernel/random/uuid)
{
  printf 'INSTALL_UID=%q\n' "$(id -u)"
  printf 'INSTALL_HOME=%q\n' "$HOME"
  printf 'NODE_NAME=%q\n' "$NODE_NAME"
  printf 'LISTEN_PORT=%q\n' "$LISTEN_PORT"
  printf 'ADVERTISE_ADDRESS=%q\n' "$ADVERTISE_ADDRESS"
  printf 'INSTANCE_ID=%q\n' "$INSTANCE_ID"
} > "$temporary/config.env"
install -m 600 "$temporary/config.env" "$PREFIX/config.env"
install -m 600 "$ROOT/linux/common.sh" "$PREFIX/lib/common.sh"
install -m 600 "$ROOT/linux/rpc-result.mjs" "$PREFIX/lib/rpc-result.mjs"
install -m 700 "$ROOT/linux/control.sh" "$PREFIX/bin/orca-service"
load_config

if [[ "$no_start" == 0 ]]; then
  # Do not leak the install lock into the long-lived server process.
  "$PREFIX/bin/orca-service" start 8>&-
  rpc host name --name "$NODE_NAME" --json | "$NODE_BIN" "$PREFIX/lib/rpc-result.mjs" status >/dev/null
  if [[ "$no_pair" == 0 ]]; then "$PREFIX/bin/orca-service" pair 8>&-; fi
fi
note "Installed Orca $ORCA_VERSION at $PREFIX"
note "Control: $PREFIX/bin/orca-service {start|stop|status|pair|logs}"
note "After a container restart, run: $PREFIX/bin/orca-service start"
note 'Container creation, startup hooks, ports, Tailscale, and agent logins were left unchanged.'
