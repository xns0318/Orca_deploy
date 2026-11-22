#!/usr/bin/env node
'use strict';
// Real released binaries, encrypted mobile relay AND Windows desktop gateway bridge, with disposable profiles only.
const assert = require('node:assert/strict');
const http = require('node:http');
const { spawn, execFile, execFileSync } = require('node:child_process');
const { promisify } = require('node:util');
const { accessSync, constants, mkdtempSync, mkdirSync, openSync, closeSync, readFileSync, readdirSync, writeFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join, resolve } = require('node:path');
const { createServer } = require('node:net');
const { randomUUID } = require('node:crypto');
const { createHub } = require('../hub/orca-api.cjs');
const execFileAsync = promisify(execFile);

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
  throw new Error(`${label} timed out${last ? ` (${last.code || last.message || last.constructor.name})` : ''}`);
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
    ORCA_HUB_APP: app, ORCA_ELECTRON_NO_SANDBOX: '1',
    ORCA_HUB_REQUIRE_MONITOR: '1', ORCA_HUB_REQUIRE_BRIDGE: '1'
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
function httpJson(port, method, path, token, body = null) {
  return new Promise((resolveReq, rejectReq) => {
    const payload = body === null ? null : Buffer.from(JSON.stringify(body), 'utf8');
    const req = http.request({
      host: '127.0.0.1', port, method, path,
      headers: {
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(payload ? { 'Content-Type': 'application/json', 'Content-Length': String(payload.length) } : {})
      }
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let json = null;
        try { json = JSON.parse(text); } catch {}
        resolveReq({ statusCode: res.statusCode, text, json });
      });
    });
    req.on('error', rejectReq);
    if (payload) req.write(payload);
    req.end();
  });
}

async function main() {
  accessSync(join(app, 'orca-ide'), constants.X_OK);
  accessSync(join(server, 'bin/orca-ide'), constants.X_OK);
  const hubState = isolated('hub');
  const hub = createHub(app, hubState.profile);
  const { RuntimeClient } = hub.native('cli/runtime/client.js');
  const local = (profile) => new RuntimeClient(profile, 15000, null, null);
  const hubPort = await freePort();
  const desktopPort = await freePort();
  Object.assign(hubState.env, {
    ORCA_HUB_PORT: String(hubPort),
    ORCA_HUB_ADDRESS: `ws://127.0.0.1:${hubPort}`,
    ORCA_DESKTOP_PORT: String(desktopPort),
    ORCA_DESKTOP_BIND: '127.0.0.1'
  });
  const hubctlPath = resolve(__dirname, '../hub/hubctl');
  const hubctl = async (args, stdinText = null) => {
    const child = spawn('bash', [hubctlPath, ...args], { env: hubState.env, stdio: ['pipe', 'pipe', 'pipe'] });
    const out = [], err = [];
    child.stdout.on('data', (c) => out.push(c));
    child.stderr.on('data', (c) => err.push(c));
    if (stdinText !== null) child.stdin.write(stdinText);
    child.stdin.end();
    const code = await new Promise((r) => child.on('close', r));
    if (code !== 0) throw new Error(`hubctl ${args.join(' ')} failed (${code}): ${Buffer.concat(err).toString('utf8')}`);
    return Buffer.concat(out).toString('utf8');
  };

  const startHub = () => run('bash', [resolve(__dirname, '../hub/entrypoint.sh')], hubState.env, 'hub');
  let hubChild = startHub();
  await eventually(() => hub.health(), 'hub startup');
  await eventually(async () => { await hubctl(['health']); return true; }, 'runtime, observer and desktop bridge health');
  pass('released Electron hub, observer and desktop gateway bridge start without a desktop window');

  const nodes = [];
  async function startNodeProcess(state, name, port) {
    const endpoint = `ws://127.0.0.1:${port}`;
    const child = run(join(server, 'bin/orca-ide'), ['serve', '--no-pairing', '--bind', '0.0.0.0', '--port', String(port), '--pairing-address', endpoint, '--refuse-public'], state.env, `${name}-${port}`);
    const rpc = local(state.profile);
    await eventually(async () => (await rpc.call('status.get')).result.graphStatus === 'ready', `${name} startup`);
    return { child, rpc, endpoint, port };
  }
  async function addNode(name) {
    const state = isolated(name);
    const port = await freePort();
    const started = await startNodeProcess(state, name, port);
    const folder = join(state.home, 'workspace');
    mkdirSync(folder, { mode: 0o700 });
    execFileSync('git', ['init'], { cwd: folder, stdio: 'ignore' });
    writeFileSync(join(folder, 'marker.txt'), name);
    await started.rpc.call('repo.add', { path: folder, kind: 'folder' });
    const offer = await started.rpc.call('pairing.createOffer', { scope: 'runtime', address: started.endpoint });
    const registered = await hub.register(name, offer);
    const node = { ...state, ...started, name, folder, registered, offer };
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

  // --- Mobile relay verification (G12 zero regression) ---
  const { parsePairingCode } = hub.native('shared/remote-runtime/pairing/pairing.js');
  const { exchangeCliPairingCode } = hub.native('cli/runtime/environment-pairing-exchange.js');
  const { pairedRuntimeConnectionFromOffer } = hub.native('shared/remote-runtime/pairing/paired-runtime-connection.js');
  const { openRemoteRuntimePassthroughSocket } = hub.native('shared/remote-runtime/remote-runtime-passthrough-socket.js');
  const { remoteRuntimeClientCapabilities } = hub.native('shared/remote-runtime/remote-runtime-client-capabilities.js');
  const { decodeTerminalStreamFrame, decodeTerminalStreamText } = hub.native('shared/terminal/stream/terminal-stream-protocol.js');
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
  async function exercisePhone(node, label) {
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
    const tag = `ORCA_HUB_${label}`;
    await phone.call('terminal.send', { terminal, client, text: `echo ${tag}_$((1000+7))`, enter: true }, hostId);
    await eventually(() => phone.output.get(subscription.streamId)?.includes(`${tag}_1007`), 'executed shell output');
    return terminal;
  }
  const originalTerminal = await exercisePhone(one, 'ONE');
  await exercisePhone(two, 'TWO');
  pass('one encrypted mobile pairing reads files and operates terminals on both servers; no Windows process exists');

  // --- Windows Desktop Gateway Bridge (3 independent remote clients, zero Orca fork) ---
  const winClients = [];
  for (const cname of ['win-1', 'win-2', 'win-3']) {
    const created = JSON.parse(await hubctl(['client', 'add', cname]));
    winClients.push({ name: cname, token: created.token, state: isolated(cname) });
  }
  async function provisionDesktop(node, targets = winClients) {
    const desktopEp = (await hubctl(['desktop-endpoint', node.name])).trim();
    const seenDevices = new Set();
    for (const wc of targets) {
      const rawOffer = await node.rpc.call('pairing.createOffer', { scope: 'runtime', address: desktopEp });
      const stored = JSON.parse(await hubctl(['offer-put', wc.name, node.name], JSON.stringify(rawOffer)));
      assert.equal(stored.status, 'pending');
      seenDevices.add(stored.deviceId);
    }
    assert.equal(seenDevices.size, targets.length, `distinct deviceIds per Windows client on ${node.name}`);
  }
  async function syncDesktopClient(wc) {
    const stateRes = await httpJson(desktopPort, 'GET', '/sync/state', wc.token);
    assert.equal(stateRes.statusCode, 200);
    for (const row of stateRes.json.nodes) {
      if (row.grantStatus !== 'pending') continue;
      const claimRes = await httpJson(desktopPort, 'POST', '/sync/claim', wc.token, { node: row.name });
      assert.equal(claimRes.statusCode, 200);
      const { stdout: addOut } = await execFileAsync(join(server, 'bin/orca-ide'), [
        'environment', 'add', '--name', row.name, '--pairing-code', claimRes.json.offer.pairingUrl, '--json'
      ], { env: wc.state.env, encoding: 'utf8' });
      assert.equal(JSON.parse(addOut).ok, true);
      const { stdout: stOut } = await execFileAsync(join(server, 'bin/orca-ide'), [
        'status', '--environment', row.name, '--json'
      ], { env: wc.state.env, encoding: 'utf8' });
      assert.equal(JSON.parse(stOut).result?.graph?.state, 'ready');
      const ackRes = await httpJson(desktopPort, 'POST', '/sync/ack', wc.token, { node: row.name, nodeId: row.nodeId });
      assert.equal(ackRes.statusCode, 200);
    }
  }
  async function exerciseDesktop(wc, node, tag) {
    const rpc = new RuntimeClient(wc.state.profile, 15000, null, node.name);
    const wts = await rpc.call('worktree.list');
    const wt = wts.result.worktrees[0];
    assert(wt);
    const wtRef = `id:${wt.id}`;
    const filename = `${wc.name}-${tag}.txt`;
    const body = `desktop-write-${wc.name}-${node.name}-${tag}`;
    await rpc.call('files.write', { worktree: wtRef, relativePath: filename, content: body, expectedExecutionHostId: 'local' });
    const read = await rpc.call('files.read', { worktree: wtRef, relativePath: filename });
    assert.equal(read.result.content, body);
    const gitSt = await rpc.call('git.status', { worktree: wtRef });
    assert.equal(gitSt.ok, true);
  }

  await provisionDesktop(one);
  await provisionDesktop(two);
  for (const wc of winClients) await syncDesktopClient(wc);
  // Plaintext offers must be burned on hub disk after ack.
  assert(!readFileSync(join(hubState.profile, 'windows-bridge.json'), 'utf8').includes('orca://pair?code='));
  for (const wc of winClients) {
    await exerciseDesktop(wc, one, 'initial');
    await exerciseDesktop(wc, two, 'initial');
  }
  pass('3 independent Windows clients sync via gateway bridge, burn offers on ack, and run files.write/files.read/git.status concurrently through /node/<name>');

  // Dynamic 3rd container: discovered by phone + all 3 Windows clients.
  const three = await addNode('node-three');
  await exercisePhone(three, 'THREE');
  await provisionDesktop(three);
  for (const wc of winClients) {
    await syncDesktopClient(wc);
    await exerciseDesktop(wc, three, 'added');
  }
  pass('newly registered third server is discovered and operated by both phone and all 3 Windows clients');

  // Hub restart: preserves phone pairing, desktop clients, and existing Windows saved endpoints!
  const beforeRestart = hub.list();
  phone.close();
  await stop(hubChild);
  hubChild = startHub();
  await eventually(() => hub.health(), 'hub restart');
  await eventually(async () => { await hubctl(['health']); return true; }, 'bridge ready after hub restart');
  assert.deepEqual(hub.list(), beforeRestart);
  phone = await openPhone();
  const hostId = `runtime:${one.registered.id}`;
  const client = { id: saved.deviceToken, type: 'mobile' };
  const subscription = await phone.call('terminal.subscribe', {
    terminal: originalTerminal, client, viewport: { cols: 80, rows: 24 }, capabilities: { terminalBinaryStream: 1 }
  }, hostId);
  await phone.call('terminal.send', { terminal: originalTerminal, client, text: 'echo SAME_SESSION_$((2000+9))', enter: true }, hostId);
  await eventually(() => phone.output.get(subscription.streamId)?.includes('SAME_SESSION_2009'), 'original terminal after hub restart');
  await exercisePhone(one, 'RESTART_ONE');
  await exercisePhone(three, 'RESTART_THREE');
  await exerciseDesktop(winClients[0], one, 'after-hub-restart');
  await exerciseDesktop(winClients[1], three, 'after-hub-restart');
  pass('hub restart preserves mobile credentials, original terminal, and all Windows gateway routes without re-pairing');

  // Container IP/port change (G07): restart node-two on a brand-new port, update hub registration -> Windows reconnects with ZERO re-pairing!
  await stop(two.child);
  const newPort = await freePort();
  const restartedTwo = await startNodeProcess(two, two.name, newPort);
  two.child = restartedTwo.child;
  two.rpc = restartedTwo.rpc;
  two.endpoint = restartedTwo.endpoint;
  two.port = newPort;
  const refreshedOffer = await two.rpc.call('pairing.createOffer', { scope: 'runtime', address: two.endpoint });
  await hub.register(two.name, refreshedOffer);
  await exerciseDesktop(winClients[0], two, 'after-ip-change');
  await exerciseDesktop(winClients[1], two, 'after-ip-change');
  pass('container endpoint change is transparent to Windows clients via /node/<name> with zero re-pairing');

  // Node removal (G08) + single Windows client revocation (G10)
  await hubctl(['remove', three.name]);
  const stAfterRm = await httpJson(desktopPort, 'GET', '/sync/state', winClients[0].token);
  assert.equal(stAfterRm.statusCode, 200);
  assert(!stAfterRm.json.nodes.some((n) => n.name === three.name));

  await hubctl(['client', 'revoke', 'win-3']);
  const revokedRes = await httpJson(desktopPort, 'GET', '/sync/state', winClients[2].token);
  assert.equal(revokedRes.statusCode, 401);
  const stillOkRes = await httpJson(desktopPort, 'GET', '/sync/state', winClients[0].token);
  assert.equal(stillOkRes.statusCode, 200);
  await exerciseDesktop(winClients[0], one, 'after-win3-revoke');
  pass('node removal hides node from sync; revoking win-3 returns HTTP 401 without affecting win-1, win-2 or phone');

  console.log('Live protocol checks passed (mobile relay + 3-client Windows gateway bridge). Real Docker/Tailscale/Windows UI still need host acceptance.');
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
