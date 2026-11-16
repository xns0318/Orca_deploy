#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export HOME="$work/home" GATEWAY_FIXTURE="$work/docker"
unset XDG_DATA_HOME DOCKER_HOST DOCKER_CONTEXT
mkdir -p "$HOME" "$GATEWAY_FIXTURE" "$work/bin"
cp "$ROOT/tests/fixtures/docker.mjs" "$work/bin/docker"
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH"
installer="$ROOT/gateway/install.sh"
output="$work/output"
key="$work/gateway key.authkey"
printf 'tskey-auth-TEST_ONLY_PRIVATE_KEY\n' > "$key"
chmod 600 "$key"

pass() { printf 'PASS: %s\n' "$*"; }
expect_failure() {
  if "$@" >"$output" 2>&1; then printf 'Unexpected success: %s\n' "$*" >&2; exit 1; fi
}
source "$ROOT/linux/network.sh"
for subnet in 10.0.0.0/8 172.16.0.0/12 172.17.0.0/16 192.168.0.0/16 10.0.0.1/32; do
  private_ipv4_subnet "$subnet"
done
for subnet in 0.0.0.0/0 172.16.0.0/11 172.17.1.0/16 192.168.0.0/15 10.0.0.0/7 10.01.0.0/16 256.1.0.0/16; do
  if private_ipv4_subnet "$subnet"; then printf 'Unexpected subnet acceptance: %s\n' "$subnet"; exit 1; fi
done
pass 'subnet validation refuses broad, public, noncanonical and malformed routes'

bash "$installer" --network bridge --dry-run >"$output" 2>&1
rg -q '172.17.0.0/16' "$output"
[[ ! -d "$HOME/.local" && ! -f "$GATEWAY_FIXTURE/state.json" ]]
node -e 'const a=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse);if(a.some(x=>!["context","version","network","container","volume"].includes(x[0])||["create","start","connect"].includes(x[1])))process.exit(1)' "$GATEWAY_FIXTURE/commands.jsonl"
pass 'dry run reads configuration without creating resources or credential files'

expect_failure env FIXTURE_DOCKER_ENDPOINT=tcp://remote:2376 bash "$installer" --dry-run
rg -q 'local Unix socket' "$output"
expect_failure env FIXTURE_DRIVER=overlay bash "$installer" --dry-run
rg -q 'existing bridge network' "$output"
expect_failure env FIXTURE_SUBNET=0.0.0.0/0 bash "$installer" --dry-run
rg -q 'canonical private IPv4' "$output"
expect_failure env FIXTURE_ICC=false bash "$installer" --dry-run
rg -q 'Inter-container connectivity' "$output"
expect_failure env FIXTURE_INTERNAL=true bash "$installer" --dry-run
rg -q 'outbound access' "$output"
expect_failure bash "$installer" --network bridge --network bridge --dry-run
rg -q 'Duplicate network' "$output"
pass 'unsupported daemon/network configurations fail before creation'

expect_failure env XDG_DATA_HOME="$ROOT/.gateway-test-$BASHPID" bash "$installer" --auth-key-file "$key"
rg -q 'credentials outside this repository' "$output"
[[ ! -e "$ROOT/.gateway-test-$BASHPID" ]]
expect_failure bash "$installer" --network bridge </dev/null
rg -q 'auth-key-file' "$output"
chmod 644 "$key"
expect_failure bash "$installer" --auth-key-file "$key"
rg -q 'permissions' "$output"
chmod 600 "$key"
[[ ! -f "$GATEWAY_FIXTURE/state.json" ]]
pass 'missing or broadly readable auth keys prevent resource creation'

bash "$installer" --network bridge --network agents --auth-key-file "$key" >"$output" 2>&1
rg -q '172.17.0.0/16' "$output"
rg -q '10.88.0.0/24' "$output"
rg -q 'local health check passed' "$output"
node - "$GATEWAY_FIXTURE/commands.jsonl" <<'NODE'
const fs = require('fs');
const calls = fs.readFileSync(process.argv[2], 'utf8').trim().split('\n').map(JSON.parse);
const create = calls.find(args => args[0] === 'create');
if (!create) throw Error('No container creation');
for (const value of ['TS_USERSPACE=true', 'TS_AUTH_ONCE=true', 'TS_AUTHKEY=file:/var/lib/tailscale/bootstrap.authkey', 'unless-stopped', '--cap-drop', 'ALL']) {
  if (!create.includes(value)) throw Error(`Missing argument: ${value}`);
}
for (const value of ['--privileged', '--cap-add', '--device', '--sysctl', '--publish', '-p']) {
  if (create.includes(value)) throw Error(`Unexpected permission or exposure: ${value}`);
}
if (!/^ghcr\.io\/tailscale\/tailscale:v1\.104\.7@sha256:[a-f0-9]{64}$/.test(create.at(-1))) throw Error('Image is not pinned');
if (!calls.some(args => args.join(' ') === 'network connect agents orca-gateway')) throw Error('Additional network not attached');
if (create.some(value => value.includes('docker.sock'))) throw Error('Docker socket mounted into gateway');
if (create.some(value => value.startsWith('type=bind,'))) throw Error('Host credential file bind-mounted');
if (calls.findIndex(args => args[0] === 'cp') > calls.findIndex(args => args[0] === 'start')) throw Error('Credentials copied after startup');
NODE
! rg -q 'tskey-auth-TEST_ONLY_PRIVATE_KEY' "$output" "$GATEWAY_FIXTURE/commands.jsonl"
pass 'one unprivileged, digest-pinned gateway serves multiple existing networks without leaking its key'

cp "$GATEWAY_FIXTURE/state.json" "$work/before.json"
bash "$installer" --network bridge --network agents >"$output" 2>&1
cmp "$GATEWAY_FIXTURE/state.json" "$work/before.json"
expect_failure bash "$installer" --network bridge
rg -q 'configuration changed' "$output"
expect_failure env FIXTURE_CONTAINER_OWNER=unrelated bash "$installer" --network bridge --network agents
rg -q 'belongs to another deployment' "$output"
expect_failure env FIXTURE_VOLUME_OWNER=unrelated bash "$installer" --network bridge --network agents
rg -q 'belongs to another deployment' "$output"
cmp "$GATEWAY_FIXTURE/state.json" "$work/before.json"
pass 'reruns preserve identity and refuse unrelated resources or changed topology'

expect_failure env FIXTURE_HEALTH=unhealthy bash "$installer" --network bridge --network agents
rg -q 'health check failed' "$output"
expect_failure env FIXTURE_HEALTH=starting bash "$installer" --network bridge --network agents --wait-seconds 1
rg -q 'startup timed out' "$output"
cmp "$GATEWAY_FIXTURE/state.json" "$work/before.json"
pass 'unhealthy and timed-out startups fail while preserving state'

mkdir "$work/copy-retry"
expect_failure env GATEWAY_FIXTURE="$work/copy-retry" FIXTURE_COPY_FAIL=1 bash "$installer" --auth-key-file "$key"
env GATEWAY_FIXTURE="$work/copy-retry" bash "$installer" --auth-key-file "$key" >"$output" 2>&1
rg -q 'local health check passed' "$output"
pass 'a failed initial credential copy can be retried without replacing the container'
printf 'Gateway fixture tests passed. No real Docker container or Tailscale device was created.\n'
