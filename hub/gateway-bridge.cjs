'use strict';
const http = require('node:http');
const net = require('node:net');
const { watch, existsSync } = require('node:fs');
const { join } = require('node:path');
const { createHub, desktopEndpoint } = require('./orca-api.cjs');
const { createBridgeStore, NAME_RE } = require('./bridge-store.cjs');

const MAX_BODY_BYTES = 4096;
const UPSTREAM_CONNECT_TIMEOUT_MS = 10000;
const NODE_PATH_RE = /^\/node\/([a-zA-Z0-9][a-zA-Z0-9._-]{0,62})$/;

function isLoopbackAddress(address) {
  return address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1';
}

function sendJson(res, statusCode, body) {
  const payload = Buffer.from(JSON.stringify(body), 'utf8');
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': String(payload.length),
    'Cache-Control': 'no-store'
  });
  res.end(payload);
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on('data', (chunk) => {
      total += chunk.length;
      if (total > MAX_BODY_BYTES) {
        reject(Object.assign(new Error('body_too_large'), { statusCode: 413 }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        const text = Buffer.concat(chunks).toString('utf8');
        const parsed = text.trim() ? JSON.parse(text) : {};
        if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
          reject(Object.assign(new Error('invalid_json'), { statusCode: 400 }));
          return;
        }
        resolve(parsed);
      } catch {
        reject(Object.assign(new Error('invalid_json'), { statusCode: 400 }));
      }
    });
    req.on('error', reject);
  });
}

function parseUpstreamTarget(endpoint) {
  try {
    const url = new URL(endpoint);
    if (url.protocol !== 'ws:' && url.protocol !== 'wss:') return null;
    const host = url.hostname.replace(/^\[|\]$/g, '');
    const port = Number(url.port || (url.protocol === 'wss:' ? 443 : 80));
    if (!host || !Number.isInteger(port) || port < 1 || port > 65535) return null;
    return { host, port, endpoint };
  } catch {
    return null;
  }
}

function writeHttpErrorAndClose(socket, statusLine) {
  try {
    socket.end(`HTTP/1.1 ${statusLine}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
  } catch {
    try { socket.destroy(); } catch {}
  }
}

function buildUpgradeRequest(req, target) {
  const lines = [`GET / HTTP/${req.httpVersion || '1.1'}`];
  const hostHeader = target.host.includes(':') ? `[${target.host}]:${target.port}` : `${target.host}:${target.port}`;
  let sawHost = false;
  for (let i = 0; i < req.rawHeaders.length; i += 2) {
    const key = req.rawHeaders[i];
    const value = req.rawHeaders[i + 1];
    if (key.toLowerCase() === 'host') {
      lines.push(`Host: ${hostHeader}`);
      sawHost = true;
    } else {
      lines.push(`${key}: ${value}`);
    }
  }
  if (!sawHost) lines.push(`Host: ${hostHeader}`);
  return `${lines.join('\r\n')}\r\n\r\n`;
}

function createGatewayBridgeServer(options) {
  const {
    profile,
    listNodes,
    hubAddress,
    desktopPort,
    bindHost = '127.0.0.1'
  } = options;
  const store = createBridgeStore(profile);
  const activeTunnels = new Map(); // nodeName -> Set<{ clientSocket, upstream, endpoint }>
  let boundPort = Number(desktopPort);

  const currentNodes = async () => {
    try {
      return await listNodes();
    } catch {
      return [];
    }
  };

  const currentNodesByName = async () => new Map((await currentNodes()).map((row) => [row.name, row]));

  const endpointForNode = (name) => desktopEndpoint(hubAddress, boundPort || desktopPort, name);

  const trackTunnel = (nodeName, tunnel) => {
    let set = activeTunnels.get(nodeName);
    if (!set) {
      set = new Set();
      activeTunnels.set(nodeName, set);
    }
    set.add(tunnel);
    const cleanup = () => {
      set.delete(tunnel);
      if (set.size === 0) activeTunnels.delete(nodeName);
    };
    tunnel.clientSocket.once('close', cleanup);
    tunnel.upstream.once('close', cleanup);
  };

  const reconcileTunnels = async () => {
    const byName = await currentNodesByName();
    for (const [nodeName, tunnels] of activeTunnels.entries()) {
      const row = byName.get(nodeName);
      for (const tunnel of tunnels) {
        if (!row || row.endpoint !== tunnel.endpoint) {
          try { tunnel.clientSocket.destroy(); } catch {}
          try { tunnel.upstream.destroy(); } catch {}
        }
      }
    }
  };

  const server = http.createServer(async (req, res) => {
    const method = req.method || 'GET';
    const rawUrl = req.url || '/';
    const pathname = rawUrl.split('?')[0];

    if (method === 'GET' && pathname === '/healthz') {
      if (!isLoopbackAddress(req.socket.remoteAddress || '')) {
        sendJson(res, 403, { ok: false, error: 'forbidden' });
        return;
      }
      sendJson(res, 200, { ok: true, port: boundPort || Number(desktopPort) });
      return;
    }

    if (pathname.startsWith('/sync/')) {
      const client = store.authenticate(req.headers.authorization);
      if (!client) {
        sendJson(res, 401, { ok: false, error: 'unauthorized' });
        return;
      }
      store.touchClient(client);

      if (method === 'GET' && pathname === '/sync/state') {
        const nodes = store.stateForClient(client, await currentNodes(), endpointForNode);
        sendJson(res, 200, { ok: true, client, nodes });
        return;
      }

      if (method === 'POST' && pathname === '/sync/claim') {
        try {
          const body = await readJsonBody(req);
          if (typeof body.node !== 'string' || !NAME_RE.test(body.node) || body.node.toLowerCase() === 'local') {
            sendJson(res, 400, { ok: false, error: 'invalid_node' });
            return;
          }
          const result = store.claimOffer(client, body.node, await currentNodesByName());
          if (!result.ok) {
            sendJson(res, result.statusCode, { ok: false, error: result.error });
            return;
          }
          sendJson(res, 200, { ok: true, offer: result.offer });
        } catch (error) {
          sendJson(res, error.statusCode || 400, { ok: false, error: 'invalid_request' });
        }
        return;
      }

      if (method === 'POST' && pathname === '/sync/ack') {
        try {
          const body = await readJsonBody(req);
          if (typeof body.node !== 'string' || !NAME_RE.test(body.node) || body.node.toLowerCase() === 'local') {
            sendJson(res, 400, { ok: false, error: 'invalid_node' });
            return;
          }
          const nodeId = typeof body.nodeId === 'string' ? body.nodeId : undefined;
          const result = store.ackOffer(client, body.node, nodeId);
          if (!result.ok) {
            sendJson(res, result.statusCode, { ok: false, error: result.error });
            return;
          }
          sendJson(res, 200, { ok: true, node: result.node, nodeId: result.nodeId, status: result.status });
        } catch (error) {
          sendJson(res, error.statusCode || 400, { ok: false, error: 'invalid_request' });
        }
        return;
      }
    }

    sendJson(res, 404, { ok: false, error: 'not_found' });
  });

  server.on('upgrade', async (req, clientSocket, head) => {
    const upgradeHeader = typeof req.headers.upgrade === 'string' ? req.headers.upgrade.toLowerCase() : '';
    const match = NODE_PATH_RE.exec(req.url || '');
    if (upgradeHeader !== 'websocket' || !match) {
      writeHttpErrorAndClose(clientSocket, '404 Not Found');
      return;
    }
    const nodeName = match[1];
    if (nodeName.toLowerCase() === 'local') {
      writeHttpErrorAndClose(clientSocket, '404 Not Found');
      return;
    }
    const row = (await currentNodesByName()).get(nodeName);
    const target = row ? parseUpstreamTarget(row.endpoint) : null;
    if (!target) {
      writeHttpErrorAndClose(clientSocket, '404 Not Found');
      return;
    }

    let settled = false;
    const upstream = net.connect({ host: target.host, port: target.port });
    upstream.setTimeout(UPSTREAM_CONNECT_TIMEOUT_MS, () => {
      if (!settled) {
        settled = true;
        upstream.destroy();
        writeHttpErrorAndClose(clientSocket, '504 Gateway Timeout');
      }
    });

    upstream.once('connect', () => {
      settled = true;
      upstream.setTimeout(0);
      clientSocket.setNoDelay(true);
      upstream.setNoDelay(true);
      const tunnel = { clientSocket, upstream, endpoint: target.endpoint };
      trackTunnel(nodeName, tunnel);
      upstream.write(buildUpgradeRequest(req, target));
      if (head && head.length > 0) upstream.write(head);
      upstream.pipe(clientSocket);
      clientSocket.pipe(upstream);
    });

    upstream.on('error', () => {
      if (!settled) {
        settled = true;
        writeHttpErrorAndClose(clientSocket, '502 Bad Gateway');
      } else {
        try { clientSocket.destroy(); } catch {}
      }
    });

    clientSocket.on('error', () => {
      try { upstream.destroy(); } catch {}
    });
  });

  let watcher = null;
  let sweep = null;

  const startWatching = () => {
    try {
      if (existsSync(profile)) {
        watcher = watch(profile, (_event, filename) => {
          if (!filename || filename === 'orca-environments.json') reconcileTunnels();
        });
        watcher.on('error', () => {});
      }
    } catch {}
    sweep = setInterval(reconcileTunnels, 5000);
    sweep.unref?.();
  };

  const stop = () => new Promise((resolve) => {
    if (watcher) { try { watcher.close(); } catch {} watcher = null; }
    if (sweep) { clearInterval(sweep); sweep = null; }
    for (const tunnels of activeTunnels.values()) {
      for (const tunnel of tunnels) {
        try { tunnel.clientSocket.destroy(); } catch {}
        try { tunnel.upstream.destroy(); } catch {}
      }
    }
    activeTunnels.clear();
    server.close(() => resolve());
    if (typeof server.closeAllConnections === 'function') server.closeAllConnections();
  });

  return {
    server,
    store,
    reconcileTunnels,
    activeTunnelCount(nodeName) {
      return activeTunnels.get(nodeName)?.size || 0;
    },
    listen() {
      return new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(Number(desktopPort), bindHost, () => {
          server.off('error', reject);
          const addr = server.address();
          if (addr && typeof addr === 'object' && addr.port) boundPort = addr.port;
          startWatching();
          resolve(addr);
        });
      });
    },
    stop
  };
}

async function main() {
  const profile = process.env.ORCA_USER_DATA_PATH;
  const app = process.env.ORCA_HUB_APP || '/opt/Orca';
  const hubAddress = process.env.ORCA_HUB_ADDRESS || `ws://127.0.0.1:${process.env.ORCA_HUB_PORT || '6768'}`;
  const desktopPort = process.env.ORCA_DESKTOP_PORT || '6769';
  const bindHost = process.env.ORCA_DESKTOP_BIND || '127.0.0.1';
  const hub = createHub(app, profile);
  const bridge = createGatewayBridgeServer({
    profile,
    listNodes: () => hub.list(),
    hubAddress,
    desktopPort,
    bindHost
  });
  await bridge.listen();
  const shutdown = () => {
    bridge.stop().finally(() => process.exit(0));
  };
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, shutdown);
}

if (require.main === module) {
  main().catch(() => {
    console.error('Orca desktop gateway bridge exited; no credentials were printed.');
    process.exitCode = 1;
  });
}

module.exports = { createGatewayBridgeServer, parseUpstreamTarget };
