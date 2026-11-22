'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const net = require('node:net');
const { mkdtempSync, readFileSync, rmSync, statSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { createBridgeStore } = require('../hub/bridge-store.cjs');
const { createGatewayBridgeServer } = require('../hub/gateway-bridge.cjs');

function httpRequest(port, method, path, headers = {}, body = null) {
  return new Promise((resolve, reject) => {
    const payload = body === null ? null : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body), 'utf8');
    const req = http.request({
      host: '127.0.0.1',
      port,
      method,
      path,
      headers: {
        ...headers,
        ...(payload ? { 'Content-Type': 'application/json', 'Content-Length': String(payload.length) } : {})
      }
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let json = null;
        try { json = JSON.parse(text); } catch {}
        resolve({ statusCode: res.statusCode, text, json });
      });
    });
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

test('bridge store hashes client tokens, burns offers on ack, and isolates revocation', () => {
  const dir = mkdtempSync(join(tmpdir(), 'orca-bridge-store-'));
  try {
    const store = createBridgeStore(dir);
    const c1 = store.addClient('win-1');
    const c2 = store.addClient('win-2');
    assert(c1.token.startsWith('orca_win_'));
    assert.notEqual(c1.token, c2.token);
    assert.throws(() => store.addClient('WIN-1'), /already exists/);

    // Plaintext token must never be stored on disk.
    const rawDisk = readFileSync(store.statePath, 'utf8');
    assert(!rawDisk.includes(c1.token));
    assert(!rawDisk.includes(c2.token));
    assert.equal(statSync(store.statePath).mode & 0o777, 0o600);

    assert.equal(store.authenticate(`Bearer ${c1.token}`), 'win-1');
    assert.equal(store.authenticate(`Bearer ${c2.token}`), 'win-2');
    assert.equal(store.authenticate('Bearer invalid_token_value_1234567890'), null);

    const nodes = [{ id: 'env-1', name: 'dev-01', endpoint: 'ws://172.17.0.5:6768' }];
    const byName = new Map(nodes.map((n) => [n.name, n]));
    store.putOffer({
      client: 'win-1',
      node: 'dev-01',
      nodeId: 'env-1',
      deviceId: 'dev-id-1',
      endpoint: 'ws://100.69.64.76:6769/node/dev-01',
      pairingUrl: 'orca://pair?code=WIN1_SECRET_CODE'
    });
    store.putOffer({
      client: 'win-2',
      node: 'dev-01',
      nodeId: 'env-1',
      deviceId: 'dev-id-2',
      endpoint: 'ws://100.69.64.76:6769/node/dev-01',
      pairingUrl: 'orca://pair?code=WIN2_SECRET_CODE'
    });

    assert.equal(store.hasValidGrant('win-1', 'dev-01', 'env-1'), true);
    assert.equal(store.hasValidGrant('win-1', 'dev-01', 'env-other'), false);

    // Claim is idempotent until ack, then plaintext offer is burned.
    const claimed1 = store.claimOffer('win-1', 'dev-01', byName);
    assert.equal(claimed1.ok, true);
    assert.equal(claimed1.offer.pairingUrl, 'orca://pair?code=WIN1_SECRET_CODE');
    assert.equal(store.claimOffer('win-1', 'dev-01', byName).ok, true);

    const acked = store.ackOffer('win-1', 'dev-01', 'env-1');
    assert.equal(acked.ok, true);
    assert.equal(store.claimOffer('win-1', 'dev-01', byName).ok, false);
    assert(!readFileSync(store.statePath, 'utf8').includes('WIN1_SECRET_CODE'));
    assert(readFileSync(store.statePath, 'utf8').includes('WIN2_SECRET_CODE'));

    // Revoking win-2 burns its pending offer and rejects auth, without affecting win-1.
    const revoked = store.revokeClient('win-2');
    assert.equal(revoked.devices.length, 1);
    assert.equal(revoked.devices[0].deviceId, 'dev-id-2');
    assert.equal(store.authenticate(`Bearer ${c2.token}`), null);
    assert.equal(store.authenticate(`Bearer ${c1.token}`), 'win-1');
    assert(!readFileSync(store.statePath, 'utf8').includes('WIN2_SECRET_CODE'));

    // Removing node clears grants across all clients.
    store.removeNode('dev-01');
    assert.equal(store.hasValidGrant('win-1', 'dev-01', 'env-1'), false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('gateway bridge serves authenticated sync API and transparent WS path proxy with tunnel revocation', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'orca-bridge-http-'));
  let upstreamServer = null;
  let bridge = null;
  try {
    // Mock WebSocket upstream echoing upgraded request path and arbitrary binary payloads.
    let lastUpgradeLine = '';
    upstreamServer = net.createServer((socket) => {
      let upgraded = false;
      let buf = Buffer.alloc(0);
      socket.on('data', (chunk) => {
        if (!upgraded) {
          buf = Buffer.concat([buf, chunk]);
          const idx = buf.indexOf('\r\n\r\n');
          if (idx === -1) return;
          const headerText = buf.subarray(0, idx).toString('utf8');
          lastUpgradeLine = headerText.split('\r\n')[0];
          upgraded = true;
          socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n');
          const rest = buf.subarray(idx + 4);
          if (rest.length) socket.write(rest);
        } else {
          socket.write(chunk);
        }
      });
    });
    await new Promise((r) => upstreamServer.listen(0, '127.0.0.1', r));
    const upstreamPort = upstreamServer.address().port;

    let nodes = [{ id: 'env-1', name: 'dev-01', endpoint: `ws://127.0.0.1:${upstreamPort}` }];
    bridge = createGatewayBridgeServer({
      profile: dir,
      listNodes: () => nodes,
      hubAddress: 'ws://100.69.64.76:6768',
      desktopPort: 0,
      bindHost: '127.0.0.1'
    });
    const addr = await bridge.listen();
    const port = addr.port;

    // Healthz works on loopback.
    const health = await httpRequest(port, 'GET', '/healthz');
    assert.equal(health.statusCode, 200);
    assert.equal(health.json.ok, true);

    // Unauthenticated sync requests are rejected.
    assert.equal((await httpRequest(port, 'GET', '/sync/state')).statusCode, 401);

    const win1 = bridge.store.addClient('win-1');
    bridge.store.putOffer({
      client: 'win-1',
      node: 'dev-01',
      nodeId: 'env-1',
      deviceId: 'dev-id-1',
      endpoint: `ws://127.0.0.1:${port}/node/dev-01`,
      pairingUrl: 'orca://pair?code=BRIDGE_TEST_CODE'
    });

    const auth = { Authorization: `Bearer ${win1.token}` };
    const stateRes = await httpRequest(port, 'GET', '/sync/state', auth);
    assert.equal(stateRes.statusCode, 200);
    assert.equal(stateRes.json.nodes.length, 1);
    assert.equal(stateRes.json.nodes[0].grantStatus, 'pending');

    const claimRes = await httpRequest(port, 'POST', '/sync/claim', auth, { node: 'dev-01' });
    assert.equal(claimRes.statusCode, 200);
    assert.equal(claimRes.json.offer.pairingUrl, 'orca://pair?code=BRIDGE_TEST_CODE');

    const ackRes = await httpRequest(port, 'POST', '/sync/ack', auth, { node: 'dev-01', nodeId: 'env-1' });
    assert.equal(ackRes.statusCode, 200);
    assert.equal((await httpRequest(port, 'POST', '/sync/claim', auth, { node: 'dev-01' })).statusCode, 404);

    // Reject path traversal & unknown nodes on Upgrade.
    const badUpgrade = await new Promise((resolve, reject) => {
      const s = net.connect(port, '127.0.0.1', () => {
        s.write('GET /node/../etc HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n');
      });
      const chunks = [];
      s.on('data', (c) => chunks.push(c));
      s.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
      s.on('error', reject);
    });
    assert(badUpgrade.startsWith('HTTP/1.1 404'));

    // Valid WS upgrade rewrites /node/dev-01 -> / and pipes raw binary bytes.
    const tunnelSocket = net.connect(port, '127.0.0.1');
    await new Promise((r) => tunnelSocket.once('connect', r));
    tunnelSocket.write('GET /node/dev-01 HTTP/1.1\r\nHost: 100.69.64.76:6769\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n');
    const handshakeResp = await new Promise((resolve) => tunnelSocket.once('data', resolve));
    assert(handshakeResp.toString('utf8').startsWith('HTTP/1.1 101'));
    assert.equal(lastUpgradeLine, 'GET / HTTP/1.1');

    const binaryFrame = Buffer.from([0xde, 0xad, 0xbe, 0xef, 0x01, 0x02]);
    tunnelSocket.write(binaryFrame);
    const echoed = await new Promise((resolve) => tunnelSocket.once('data', resolve));
    assert.deepEqual(echoed, binaryFrame);
    assert.equal(bridge.activeTunnelCount('dev-01'), 1);

    // Removing the node immediately closes active tunnels on reconciliation.
    const closedPromise = new Promise((resolve) => tunnelSocket.once('close', () => resolve(true)));
    nodes = [];
    bridge.reconcileTunnels();
    assert.equal(await closedPromise, true);
    assert.equal(bridge.activeTunnelCount('dev-01'), 0);
  } finally {
    if (bridge) await bridge.stop();
    if (upstreamServer) await new Promise((r) => upstreamServer.close(r));
    rmSync(dir, { recursive: true, force: true });
  }
});
