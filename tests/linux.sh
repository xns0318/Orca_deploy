#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d)
service=
unrelated=
cleanup() {
  [[ -z "$service" ]] || "$service" stop >/dev/null 2>&1 || true
  [[ -z "$unrelated" ]] || kill "$unrelated" 2>/dev/null || true
  rm -rf -- "$work"
}
trap cleanup EXIT
export HOME="$work/home"
unset XDG_DATA_HOME ORCA_DEPLOY_PREFIX
mkdir -p "$HOME" "$work/repo" "$work/mock-bin" "$work/package/orca/bin" \
  "$work/package/orca/orcad" "$work/package/orca/runtimes/node-test/bin"
cp -R "$ROOT/install.sh" "$ROOT/linux" "$ROOT/versions.lock.env" "$work/repo/"
cp "$ROOT/tests/fixtures/orca-cli.mjs" "$work/package/orca/bin/orca-ide"
cp "$(command -v node)" "$work/package/orca/runtimes/node-test/bin/node"
chmod +x "$work/package/orca/bin/orca-ide"
cp "$ROOT/tests/fixtures/server.VERSION" "$work/package/orca/VERSION"
printf 'test\n' > "$work/package/orca/orcad/.runtime-node"
export FIXTURE_ARCHIVE="$work/server.tar.gz" FIXTURE_DOWNLOADS="$work/downloads"
tar -czf "$FIXTURE_ARCHIVE" -C "$work/package" orca
hash=$(sha256sum "$FIXTURE_ARCHIVE")
hash=${hash%% *}
sed -i -E "s/^(LINUX_(X64|ARM64)_SHA256)=.*/\1=$hash/" "$work/repo/versions.lock.env"
cp "$ROOT/tests/fixtures/curl" "$work/mock-bin/curl"
cp "$ROOT/tests/fixtures/hostname" "$work/mock-bin/hostname"
chmod +x "$work/mock-bin/curl" "$work/mock-bin/hostname"
export PATH="$work/mock-bin:$PATH"
installer="$work/repo/install.sh"
prefix="$work/install with spaces"
service="$prefix/bin/orca-service"
output="$work/output"

pass() { printf 'PASS: %s\n' "$*"; }
expect_failure() {
  if "$@" >"$output" 2>&1; then printf 'Unexpected success: %s\n' "$*" >&2; exit 1; fi
}
source "$ROOT/linux/common.sh"
[[ $(server_release_version "$ROOT/tests/fixtures/server.VERSION") == 1.4.259 ]]
printf 'node 24.22.1\r\norca 1.4.259' > "$work/VERSION"
[[ $(server_release_version "$work/VERSION") == 1.4.259 ]]
for manifest in '' '1.4.259' 'orcad 1.4.259' 'orca invalid' 'orca 1.4.259 extra' $'orca 1.4.259\norca 1.4.259'; do
  printf '%s\n' "$manifest" > "$work/VERSION"
  expect_failure server_release_version "$work/VERSION"
done
expect_failure server_release_version "$work/missing-VERSION"
pass 'official VERSION metadata is parsed and missing, malformed or duplicate Orca entries are rejected'

node - "$ROOT/linux/rpc-result.mjs" <<'NODE'
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const healthy = { runtime: { reachable: true, state: 'ready' }, graph: { state: 'ready' } };
const check = (result, mode = 'health') => spawnSync(process.execPath, [process.argv[2], mode], {
  input: JSON.stringify({ ok: true, result }), encoding: 'utf8',
}).status;
assert.equal(check(healthy), 0);
for (const result of [
  {}, { healthy: true },
  { ...healthy, runtime: { reachable: false, state: 'ready' } },
  { ...healthy, runtime: { reachable: true, state: 'graph_not_ready' } },
  { ...healthy, graph: { state: 'not_running' } },
]) assert.notEqual(check(result), 0);
assert.equal(check({ machineName: 'dev-01', platform: 'linux' }, 'status'), 0);
NODE
pass 'health checks require a reachable, ready runtime and graph, not just a successful status response'

expect_failure bash "$installer" --prefix "$work/missing"
rg -q 'Supply --address' "$output"
pass 'first installation requires a reachable endpoint'

cp "$work/repo/versions.lock.env" "$work/good.env"
sed -i -E 's/^(LINUX_(X64|ARM64)_SHA256)=.*/\1=0000000000000000000000000000000000000000000000000000000000000000/' "$work/repo/versions.lock.env"
expect_failure bash "$installer" --prefix "$work/corrupt" --name test --address ws://100.64.0.1:16768
rg -q 'SHA256 mismatch' "$output"
[[ ! -e "$work/corrupt/current" ]]
cp "$work/good.env" "$work/repo/versions.lock.env"
pass 'checksum failure prevents extraction and execution'

cp "$FIXTURE_ARCHIVE" "$work/good.tar.gz"
sed -i 's/^orca 1\.4\.259$/orca 1.4.258/' "$work/package/orca/VERSION"
tar -czf "$FIXTURE_ARCHIVE" -C "$work/package" orca
hash=$(sha256sum "$FIXTURE_ARCHIVE")
hash=${hash%% *}
sed -i -E "s/^(LINUX_(X64|ARM64)_SHA256)=.*/\1=$hash/" "$work/repo/versions.lock.env"
expect_failure bash "$installer" --prefix "$work/wrong-version" --name test --address ws://100.64.0.1:16768
rg -q 'expected 1.4.259, found 1.4.258' "$output"
[[ ! -e "$work/wrong-version/current" && ! -f "$work/wrong-version/config.env" ]]
cp "$work/good.tar.gz" "$FIXTURE_ARCHIVE"
cp "$work/good.env" "$work/repo/versions.lock.env"
pass 'a checksum-valid archive with a different Orca version is rejected before activation'

bash "$installer" --prefix "$prefix" --name dev-01 --address ws://100.64.0.1:16768 --no-start >"$output" 2>&1
[[ -x "$service" && ! -f "$prefix/server.pid" && ! -f "$prefix/server.pairing.json" ]]
[[ $(stat -c %a "$prefix/config.env") == 600 && $(stat -c %a "$prefix") == 700 ]]
identity=$(rg '^INSTANCE_ID=' "$prefix/config.env")
pass 'install-only works in paths with spaces and keeps state private'

bash "$installer" --prefix "$prefix" --no-pair >"$output" 2>&1
"$service" status >/dev/null
[[ ! -f "$prefix/server.pairing.json" ]]
"$service" stop >/dev/null 2>&1
pass 'hub enrollment can start a node without minting an unused pairing offer'

export ORCA_ENVIRONMENT=unrelated ORCA_PAIRING_CODE=unrelated ORCA_REMOTE_PAIRING=unrelated
FIXTURE_START_DELAY_MS=1500 bash "$installer" --prefix "$prefix" >"$output" 2>&1
"$service" status >"$work/status"
node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1])); if(!r.ok||!r.result.runtime.reachable||r.result.runtime.state!=="ready")process.exit(1)' "$work/status"
[[ $(stat -c %a "$prefix/server.pairing.json") == 600 ]]
! rg -q 'TEST_PRIVATE_OFFER|orca://pair\?' "$output" "$prefix/logs/server.log"
node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync(process.argv[1])); if(p.result.endpoint!=="ws://100.64.0.1:16768")process.exit(1)' "$prefix/server.pairing.json"
node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[1])).args; for(const s of ["--supervise","--no-pairing","--refuse-public","0.0.0.0","6768"])if(!a.includes(s))process.exit(1)' "$prefix/state/fixture-server.json"
[[ $(<"$prefix/state/fixture-name") == dev-01 ]]
pass 'delayed startup waits for readiness before setting the name and creating the private pairing offer'

pid=$(<"$prefix/server.pid")
node -e 'const fs=require("node:fs");const pid=process.argv[1].split(" ")[0];const s=fs.readFileSync(`/proc/${pid}/stat`,"utf8");const session=s.slice(s.lastIndexOf(") ")+2).split(" ")[3];if(session!==pid)throw Error("Server must lead its own session");' "$pid"
pass 'the background server uses a separate session from its installer'
downloads=$(wc -l < "$FIXTURE_DOWNLOADS")
bash "$installer" --prefix "$prefix" >"$output" 2>&1
[[ $(rg '^INSTANCE_ID=' "$prefix/config.env") == "$identity" ]]
[[ $(<"$prefix/server.pid") == "$pid" && $(wc -l < "$FIXTURE_DOWNLOADS") == "$downloads" ]]
expect_failure bash "$installer" --prefix "$prefix" --port 6769
rg -q 'Stop orca-service' "$output"
pass 'reinstallation preserves process, identity, profile and cached release'

touch "$prefix/state/fail-health"
expect_failure "$service" status
expect_failure "$service" pair
rm "$prefix/state/fail-health"
pass 'failed health checks block success and new pairing output'

"$service" stop >"$output" 2>&1
[[ ! -f "$prefix/state/fixture-server.json" && -d "$prefix/state" ]]
"$service" start >"$output" 2>&1
"$service" status >/dev/null
"$service" stop >"$output" 2>&1
pass 'stop and restart preserve the profile'

bash "$installer" --prefix "$prefix" --address auto >"$output" 2>&1
rg -q '^ADVERTISE_ADDRESS=ws://172.17.0.17:6768$' "$prefix/config.env"
pid=$(<"$prefix/server.pid")
bash "$installer" --prefix "$prefix" --address auto >"$output" 2>&1
[[ $(<"$prefix/server.pid") == "$pid" ]]
expect_failure env FIXTURE_ADDRESSES='172.17.0.17 10.88.0.2' bash "$installer" --prefix "$prefix" --address auto
rg -q 'exactly one private IPv4' "$output"
expect_failure env FIXTURE_ADDRESSES='127.0.0.1 100.64.0.2 203.0.113.2' bash "$installer" --prefix "$prefix" --address auto
rg -q 'exactly one private IPv4' "$output"
"$service" stop >"$output" 2>&1
pass 'automatic private address selection is repeatable and refuses ambiguous interfaces'

sleep 120 &
unrelated=$!
source "$ROOT/linux/common.sh"
printf '%s %s\n' "$unrelated" "$(process_start_time "$unrelated")" > "$prefix/server.pid"
"$service" stop >"$output" 2>&1
kill -0 "$unrelated"
pass 'an unrelated process with a matching PID/start time is not stopped'

expect_failure bash "$installer" --prefix "$prefix" --address ws://100.64.0.1:16768/private --no-start
rg -q 'without a path' "$output"
pass 'endpoint paths are rejected'
printf 'Linux deployment tests passed. No real Orca service was started.\n'
