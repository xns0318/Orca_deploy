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
archive="$work/hub.tar.gz"
bash "$ROOT/hub/export-image.sh" --output "$archive" >"$output" 2>&1
[[ -s "$archive" && -s "$archive.sha256" ]]
expect_failure bash "$ROOT/hub/export-image.sh" --output "$archive"
pass 'image exporter creates a checksummed archive and refuses to overwrite an existing bundle'
cp "$work/before" "$HUB_FIXTURE/state.json"
expect_failure bash "$ROOT/hub/install.sh" --image-archive "$archive" --image-sha256 "$(printf '0%.0s' {1..64})"
rg -q 'checksum mismatch' "$output"
cmp "$work/before" "$HUB_FIXTURE/state.json"
expect_failure bash "$ROOT/hub/install.sh" --image-archive "$work/missing"
expect_failure bash "$ROOT/hub/install.sh" --image-sha256 bad
pass 'invalid or missing archives fail before changing gateway, image or hub state'
calls_before=$(wc -l < "$HUB_FIXTURE/commands.jsonl")
bash "$ROOT/hub/install.sh" --network bridge --image-archive "$archive" --dry-run >"$output" 2>&1
cmp "$work/before" "$HUB_FIXTURE/state.json"
bash "$ROOT/hub/install.sh" --network bridge --image-archive "$archive" >"$output" 2>&1
rg -q 'Hub ready locally' "$output"
cp "$HUB_FIXTURE/state.json" "$work/offline-installed"
bash "$ROOT/hub/install.sh" --network bridge --image-archive "$archive" >"$output" 2>&1
cmp "$work/offline-installed" "$HUB_FIXTURE/state.json"
node - "$HUB_FIXTURE/commands.jsonl" "$calls_before" <<'NODE'
const assert = require('node:assert/strict');
const calls = require('fs').readFileSync(process.argv[2], 'utf8').trim().split('\n').map(JSON.parse).slice(Number(process.argv[3]));
assert.equal(calls.filter((a) => a[0] === 'image' && a[1] === 'load').length, 1);
assert(!calls.some((a) => ['build', 'pull', 'stop', 'rm'].includes(a[0])));
NODE
pass 'offline installation loads once, skips registry/build access and preserves the working gateway'
for mismatch in arch fingerprint image; do
  cp "$work/before" "$HUB_FIXTURE/state.json"
  node - "$archive" "$work/wrong.tar.gz" "$mismatch" <<'NODE'
const fs = require('node:fs'), zlib = require('node:zlib'), crypto = require('node:crypto');
const data = JSON.parse(zlib.gunzipSync(fs.readFileSync(process.argv[2])));
if (process.argv[4] === 'image') data.image = 'other:tag';
else data.metadata[process.argv[4]] = 'wrong';
const bytes = zlib.gzipSync(JSON.stringify(data));
fs.writeFileSync(process.argv[3], bytes);
fs.writeFileSync(process.argv[3] + '.sha256', crypto.createHash('sha256').update(bytes).digest('hex') + '  wrong.tar.gz\n');
NODE
  expect_failure bash "$ROOT/hub/install.sh" --image-archive "$work/wrong.tar.gz"
  node - "$HUB_FIXTURE/state.json" <<'NODE'
const assert = require('node:assert/strict'), state = require(process.argv[2]);
assert(!state.containers['orca-hub']);
assert(!state.volumes['orca-hub-home']);
assert.equal(state.containers['orca-gateway'].id, 'gateway-id');
NODE
done
pass 'wrong architecture, fingerprint or image tag is refused before a hub is created'
cp "$work/before" "$HUB_FIXTURE/state.json"
expect_failure env HUB_FIXTURE_BUILD_FAIL=1 bash "$ROOT/hub/install.sh"
rg -q 'use hub/export-image.sh' "$output"
cmp "$work/before" "$HUB_FIXTURE/state.json"
pass 'build failures point to offline deployment and preserve existing resources'
printf 'Hub Docker fixtures passed. No real Docker or Tailscale service was started.\n'
