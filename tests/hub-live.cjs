#!/usr/bin/env node
'use strict';
// Real released binaries and the released encrypted mobile transport, with disposable profiles only.
const assert = require('node:assert/strict');
const { spawn, execFileSync } = require('node:child_process');
const { accessSync, constants, mkdtempSync, mkdirSync, openSync, closeSync, readFileSync, readdirSync, writeFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join, resolve } = require('node:path');
const { createServer } = require('node:net');
const { randomUUID } = require('node:crypto');
const { createHub } = require('../hub/orca-api.cjs');
const app = resolve(process.argv[2] || '/opt/Orca');
const server = resolve(process.argv[3] || '/opt/orca-server');
const root = mkdtempSync(join(tmpdir(), 'orca-hub-live-'));
const marker = randomUUID();
const children = [];
const sockets = [];
const delay = (ms) => new Promise((done) => setTimeout(done, ms));
const pass = (s) => console.log(`PASS: ${s}`);

async function eventually(fn, label, timeout = 60000) {
  const until = Date.now() + timeout;
  let last;
  while (Date.now() < until) {
    try { const value = await fn(); if (value) return value; } catch (error) { last = error; }
    await delay(250);
  }
  throw new Error(`${label} timed out${last ? ` (${last.code || last.constructor.name})` : ''}`);
}
async function freePort() {
  const socket = createServer();
  await new Promise((done) => socket.listen(0, '127.0.0.1', done));
  const port = socket.address().port;
  await new Promise((done) => socket.close(done));
  return port;
}
function isolated(name) {
  const home = join(root, name);
  const profile = join(home, '.config/orca');
  mkdirSync(profile, { recursive: true, mode: 0o700 });
  const env = { ...process.env };
  for (const key of Object.keys(env)) if (key.startsWith('ORCA_')) delete env[key];
  Object.assign(env, {
    HOME: home, XDG_CONFIG_HOME: join(home, '.config'), XDG_DATA_HOME: join(home, '.local/share'),
    ORCA_USER_DATA_PATH: profile, ORCA_INSTANCE_ID: `${marker}-${name}`,
    ORCA_BACKGROUND_LAUNCH: '1', ORCA_HUB_LIVE_TEST: marker,
    ORCA_HUB_APP: app, ORCA_ELECTRON_NO_SANDBOX: '1', ORCA_HUB_REQUIRE_MONITOR: '1'
  });
  return { home, profile, env };
}
function run(binary, args, env, label) {
  const log = openSync(join(root, `${label}.log`), 'a', 0o600);
  const child = spawn(binary, args, { env, detached: true, stdio: ['ignore', log, log] });
  closeSync(log);
  children.push(child);
  child.on('error', () => {});
  return child;
}
async function stop(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  process.kill(-child.pid, 'SIGTERM');
  await eventually(() => child.exitCode !== null || child.signalCode !== null, 'service stop', 20000);
}

async function main() {
  accessSync(join(app, 'orca-ide'), constants.X_OK);
  accessSync(join(server, 'bin/orca-ide'), constants.X_OK);
  const hubState = isolated('hub');
  const hub = createHub(app, hubState.profile);
  const { RuntimeClient } = hub.native('cli/runtime/client.js');
  const local = (profile) => new RuntimeClient(profile, 15000, null, null);
  const hubPort = await freePort();
  Object.assign(hubState.env, { ORCA_HUB_PORT: String(hubPort), ORCA_HUB_ADDRESS: `ws://127.0.0.1:${hubPort}` });
  const startHub = () => run('bash', [resolve(__dirname, '../hub/entrypoint.sh')], hubState.env, 'hub');
  let hubChild = startHub();
  await eventually(() => hub.health(), 'hub startup');
  await eventually(() => {
    execFileSync('bash', [resolve(__dirname, '../hub/hubctl'), 'health'], { env: hubState.env, stdio: 'ignore' });
    return true;
  }, 'runtime and observer health');
  pass('released Electron hub starts without a desktop window');
  const nodes = [];
  async function addNode(name) {
    const state = isolated(name);
    const port = await freePort();
    const endpoint = `ws://127.0.0.1:${port}`;
    run(join(server, 'bin/orca-ide'), ['serve', '--no-pairing', '--bind', '0.0.0.0', '--port', String(port), '--pairing-address', endpoint, '--refuse-public'], state.env, name);
    const rpc = local(state.profile);
    await eventually(async () => (await rpc.call('status.get')).result.graphStatus === 'ready', `${name} startup`);
    const folder = join(state.home, 'workspace');
    mkdirSync(folder, { mode: 0o700 });
    writeFileSync(join(folder, 'marker.txt'), name);
    await rpc.call('repo.add', { path: folder, kind: 'folder' });
    const offer = await rpc.call('pairing.createOffer', { scope: 'runtime', address: endpoint });
    const registered = await hub.register(name, offer);
    const node = { ...state, endpoint, name, rpc, folder, registered, offer };
    nodes.push(node);
    return node;
  }
  const one = await addNode('node-one');
  const two = await addNode('node-two');
  assert.equal(hub.list().length, 2);
  const before = readFileSync(join(hubState.profile, 'orca-environments.json'), 'utf8');
  await hub.register(one.name, one.offer);
  assert.equal(readFileSync(join(hubState.profile, 'orca-environments.json'), 'utf8'), before);
  await assert.rejects(() => hub.register(one.name, two.offer));
  assert.equal(hub.list().length, 2);
  pass('two real servers enroll; repeated enrollment is stable and identity collisions are refused');

  const { parsePairingCode } = hub.native('shared/remote-runtime/pairing/pairing.js');
  const { exchangeCliPairingCode } = hub.native('cli/runtime/environment-pairing-exchange.js');
  const { pairedRuntimeConnectionFromOffer } = hub.native('shared/remote-runtime/pairing/paired-runtime-connection.js');
  const { openRemoteRuntimePassthroughSocket } = hub.native('shared/remote-runtime/remote-runtime-passthrough-socket.js');
  const { remoteRuntimeClientCapabilities } = hub.native('shared/remote-runtime/remote-runtime-client-capabilities.js');
  const { decodeTerminalStreamFrame, decodeTerminalStreamText } = hub.native('shared/terminal/stream/terminal-stream-protocol.js');
  // Exchange once, then retain the same mobile-scoped credential throughout every scenario.
  const offer = await hub.pair(hubState.env.ORCA_HUB_ADDRESS);
  const saved = parsePairingCode(await exchangeCliPairingCode(offer.result.pairingUrl));
  assert.equal(saved.scope, 'mobile');
  async function openPhone() {
    const frames = new Map();
    const output = new Map();
    const socket = await openRemoteRuntimePassthroughSocket(
      pairedRuntimeConnectionFromOffer(saved),
      remoteRuntimeClientCapabilities().filter((c) => !c.includes('compressed')),
      {
        onText: (text) => { const frame = JSON.parse(text); if (frame.id) frames.set(frame.id, frame); },
        onBinary: (bytes) => {
          const frame = decodeTerminalStreamFrame(bytes);
          if (frame?.opcode === 1) output.set(frame.streamId, (output.get(frame.streamId) || '') + decodeTerminalStreamText(frame.payload));
        },
        onClose: () => {}
      }, { timeoutMs: 15000 }
    );
    sockets.push(socket);
    return {
      close: () => socket.close(),
      output,
      async call(method, params = {}, executionHost) {
        const id = randomUUID();
        await socket.send(JSON.stringify({ id, method, params, executionHost, deviceToken: saved.deviceToken }));
        const frame = await eventually(() => frames.get(id), method, 30000);
        if (!frame.ok) throw Object.assign(new Error(`${method}: ${frame.error?.code}`), { code: frame.error?.code });
        return frame.result;
      }
    };
  }
  let phone = await openPhone();
  async function exercise(node, label) {
    const hostId = `runtime:${node.registered.id}`;
    const hosts = await phone.call('mobileRelay.hosts.list');
    assert(hosts.hosts.some((row) => row.hostId === hostId));
    const row = await eventually(async () => {
      const listed = await phone.call('mobileRelay.hosts.worktrees', { hostId });
      return listed.worktrees?.find((entry) => entry.path === node.folder);
    }, 'phone worktrees');
    const worktree = `id:${row.worktreeId}`;
    const file = await phone.call('files.read', { worktree, relativePath: 'marker.txt' }, hostId);
    assert.equal(file.content, node.name);
    const created = await phone.call('session.tabs.createTerminal', { worktree, activate: false, select: false, navigation: 'caller' }, hostId);
    const terminal = created.tab.terminal;
    assert(terminal);
    const client = { id: saved.deviceToken, type: 'mobile' };
    const subscription = await phone.call('terminal.subscribe', {
      terminal, client, viewport: { cols: 80, rows: 24 }, capabilities: { terminalBinaryStream: 1 }
    }, hostId);
    assert.equal(subscription.type, 'subscribed');
    const marker = `ORCA_HUB_${label}`;
    await phone.call('terminal.send', { terminal, client, text: `echo ${marker}_$((1000+7))`, enter: true }, hostId);
    await eventually(() => phone.output.get(subscription.streamId)?.includes(`${marker}_1007`), 'executed shell output');
    return terminal;
  }
  const originalTerminal = await exercise(one, 'ONE');
  await exercise(two, 'TWO');
  pass('one encrypted mobile pairing reads files and operates terminals on both servers; no Windows process exists');
  const three = await addNode('node-three');
  await exercise(three, 'THREE');
  pass('the same connected phone discovers and operates a newly registered third server');
  const beforeRestart = hub.list();
  phone.close();
  await stop(hubChild);
  hubChild = startHub();
  await eventually(() => hub.health(), 'hub restart');
  assert.deepEqual(hub.list(), beforeRestart);
  phone = await openPhone();
  const hostId = `runtime:${one.registered.id}`;
  const client = { id: saved.deviceToken, type: 'mobile' };
  const subscription = await phone.call('terminal.subscribe', {
    terminal: originalTerminal, client, viewport: { cols: 80, rows: 24 }, capabilities: { terminalBinaryStream: 1 }
  }, hostId);
  await phone.call('terminal.send', { terminal: originalTerminal, client, text: 'echo SAME_SESSION_$((2000+9))', enter: true }, hostId);
  await eventually(() => phone.output.get(subscription.streamId)?.includes('SAME_SESSION_2009'), 'original terminal after hub restart');
  await exercise(one, 'RESTART_ONE');
  await exercise(three, 'RESTART_THREE');
  pass('hub restart preserves server IDs, the same mobile credential and input/output on the original remote terminal');
  console.log('Live protocol checks passed. Phone UI and the real Docker/Tailscale path require separate acceptance.');
}

async function cleanup() {
  for (const socket of sockets) socket.close();
  // Orca terminal daemons can detach. Match only this test's inherited marker, never user sessions.
  const markedPids = () => readdirSync('/proc').filter((id) => /^\d+$/.test(id)).filter((id) => {
    try { return readFileSync(`/proc/${id}/environ`, 'utf8').split('\0').includes(`ORCA_HUB_LIVE_TEST=${marker}`); }
    catch { return false; }
  });
  for (const signal of ['SIGTERM', 'SIGKILL']) {
    for (const pid of markedPids()) { try { process.kill(Number(pid), signal); } catch {} }
    await delay(1000);
  }
  for (const child of children) child.unref();
}
main().catch((error) => {
  console.error(`FAIL: ${error.message}`);
  console.error(`Private diagnostic directory: ${root}`);
  process.exitCode = 1;
}).finally(cleanup);
