#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export HOME="$work/home" HUB_FIXTURE="$work/docker"
unset XDG_DATA_HOME DOCKER_HOST DOCKER_CONTEXT
mkdir -p "$HOME" "$HUB_FIXTURE" "$work/bin"
cp "$ROOT/tests/fixtures/hub-docker.cjs" "$work/bin/docker"
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH"
source "$ROOT/versions.lock.env"
node - "$HUB_FIXTURE/state.json" "$TAILSCALE_IMAGE" <<'NODE'
const fs = require('node:fs');
fs.writeFileSync(process.argv[2], JSON.stringify({
  containers: {
    'orca-gateway': { id: 'gateway-id', image: process.argv[3], running: true, network: 'bridge', networks: { bridge: '172.17.0.18' }, volume: 'orca-gateway-state', labels: {
      'com.orca-deploy.role': 'orca-tailscale-gateway-v1', 'com.orca-deploy.networks': 'bridge', 'com.orca-deploy.routes': '172.17.0.0/16'
    } },
    'agent-one': { id: 'agent-id', running: true, networks: { bridge: '172.17.0.17' }, labels: {} }
  }, volumes: { 'orca-gateway-state': { owner: 'orca-gateway' } }, images: [], serve: {}, agentInstalled: false
}));
NODE
output="$work/output"
pass() { printf 'PASS: %s\n' "$*"; }
expect_failure() { if "$@" >"$output" 2>&1; then printf 'Unexpected success\n' >&2; exit 1; fi; }
cp "$HUB_FIXTURE/state.json" "$work/before"
bash "$ROOT/hub/install.sh" --network bridge --dry-run >"$output" 2>&1
cmp "$work/before" "$HUB_FIXTURE/state.json"
[[ ! -d "$HOME/.local" ]]
pass 'hub dry-run leaves the working gateway and all state untouched'
bash "$ROOT/hub/install.sh" --network bridge >"$output" 2>&1
rg -q 'ws://100.92.0.8:6768' "$output"
node - "$HUB_FIXTURE/commands.jsonl" <<'NODE'
const assert = require('node:assert/strict');
const calls = require('fs').readFileSync(process.argv[2], 'utf8').trim().split('\n').map(JSON.parse);
const c = calls.find((a) => a[0] === 'create');
for (const v of ['container:gateway-id', '--read-only', '--cap-drop', 'ALL', 'no-new-privileges:true', 'unless-stopped', 'type=volume,src=orca-hub-home,dst=/home/orca']) assert(c.includes(v), v);
for (const v of ['--privileged', '--cap-add', '--publish', '-p', '--device', '--hostname']) assert(!c.includes(v), v);
assert(!c.some((v) => v.includes('docker.sock')));
assert(!calls.some((a) => a[0] === 'stop' || a[0] === 'rm'));
assert(calls.some((a) => a.includes('BASE_IMAGE=debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc')));
assert(calls.some((a) => a.includes('ORCA_DEB_SHA256=7708c6187e5851002a505c1e2f11ed6485aa0d5dad52462bb33424be16e011f9')));
assert(calls.some((a) => a.includes('--tcp=6768') && a.includes('tcp://127.0.0.1:6768')));
assert(!calls.some((a) => a.includes('funnel') || a.includes('reset')));
NODE
pass 'a checksum-pinned nonprivileged hub shares the gateway namespace and enables only private TCP Serve'
cp "$HUB_FIXTURE/state.json" "$work/installed"
bash "$ROOT/hub/install.sh" --network bridge >"$output" 2>&1
cmp "$work/installed" "$HUB_FIXTURE/state.json"
expect_failure env HUB_FIXTURE_FOREIGN_HUB=1 bash "$ROOT/hub/install.sh"
expect_failure env HUB_FIXTURE_FOREIGN_VOLUME=unrelated bash "$ROOT/hub/install.sh"
expect_failure bash "$ROOT/hub/install.sh" --port 6769
rg -q 'Rerun with --recreate' "$output"
pass 'reinstall keeps identity; unrelated resources and unapproved reconfiguration are refused'
expect_failure env HUB_FIXTURE_UNHEALTHY=1 bash "$ROOT/hub/install.sh" --wait-seconds 1
rg -q 'startup timed out' "$output"
expect_failure env HUB_FIXTURE_CONFLICT=1 bash "$ROOT/hub/install.sh"
cmp "$work/installed" "$HUB_FIXTURE/state.json"
pass 'failed readiness or a Serve conflict never replaces the hub state'
bash "$ROOT/hub/connect.sh" --container agent-one --name dev-01 --dry-run >"$output" 2>&1
cmp "$work/installed" "$HUB_FIXTURE/state.json"
bash "$ROOT/hub/connect.sh" --container agent-one --name dev-01 >"$output" 2>&1
rg -q 'Container enrolled' "$output"
! rg -q 'TEST_ONLY_PRIVATE_OFFER' "$output" "$HUB_FIXTURE/commands.jsonl"
cp "$HUB_FIXTURE/state.json" "$work/enrolled"
bash "$ROOT/hub/connect.sh" --container agent-one --name dev-01 >"$output" 2>&1
rg -q 'Already enrolled' "$output"
cmp "$work/enrolled" "$HUB_FIXTURE/state.json"
expect_failure bash "$ROOT/hub/connect.sh" --container orca-hub --name bad
pass 'one-command enrollment sends offers through stdin, is repeatable and rejects infrastructure containers'
bash "$ROOT/hub/install.sh" --port 6769 --recreate >"$output" 2>&1
node - "$HUB_FIXTURE/state.json" <<'NODE'
const assert = require('node:assert/strict');
const state = require(process.argv[2]);
assert(state.registered['dev-01']);
assert.equal(state.volumes['orca-hub-home'].owner, 'orca-hub');
assert.equal(state.containers['orca-gateway'].id, 'gateway-id');
assert.equal(state.containers['orca-hub'].labels['com.orca-deploy.address'], 'ws://100.92.0.8:6769');
NODE
pass 'explicit hub recreation preserves the gateway, persisted registration and home volume'
printf 'Hub Docker fixtures passed. No real Docker or Tailscale service was started.\n'
