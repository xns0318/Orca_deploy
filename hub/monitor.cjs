'use strict';
const { readFileSync, writeFileSync, renameSync, mkdirSync } = require('node:fs');
const { join } = require('node:path');
const { randomUUID } = require('node:crypto');
const { createHub } = require('./orca-api.cjs');
const profile = process.env.ORCA_USER_DATA_PATH;
const hub = createHub(process.env.ORCA_HUB_APP || '/opt/Orca', profile);
const address = `ws://127.0.0.1:${process.env.ORCA_HUB_PORT || '6768'}`;
const credentialPath = join(profile, 'hub-monitor.pairing.json');
const heartbeatPath = join(profile, 'hub-monitor.heartbeat');
const { parsePairingCode } = hub.native('shared/remote-runtime/pairing/pairing.js');
const { exchangeCliPairingCode } = hub.native('cli/runtime/environment-pairing-exchange.js');
const { pairedRuntimeConnectionFromOffer } = hub.native('shared/remote-runtime/pairing/paired-runtime-connection.js');
const { openRemoteRuntimePassthroughSocket } = hub.native('shared/remote-runtime/remote-runtime-passthrough-socket.js');
const { remoteRuntimeClientCapabilities } = hub.native('shared/remote-runtime/remote-runtime-client-capabilities.js');
const capabilities = remoteRuntimeClientCapabilities().filter((value) => !value.includes('compressed'));
const delay = (ms) => new Promise((done) => setTimeout(done, ms));
let stopped = false;
let connection = null;
let pairing = null;
const pending = new Map();
function persist(file, value) {
  writeFileSync(`${file}.tmp`, value, { mode: 0o600 });
  renameSync(`${file}.tmp`, file);
}
function close() {
  const previous = connection;
  connection = null;
  previous?.close();
  for (const { reject, timer } of pending.values()) { clearTimeout(timer); reject(new Error('disconnected')); }
  pending.clear();
}
async function open() {
  if (!pairing) {
    try { pairing = parsePairingCode(JSON.parse(readFileSync(credentialPath, 'utf8')).pairingUrl); } catch {}
    if (pairing?.endpoint !== address || pairing.scope !== 'mobile') pairing = null;
  }
  if (!pairing) {
    const offer = await hub.pair(address);
    const pairingUrl = await exchangeCliPairingCode(offer.result.pairingUrl);
    pairing = parsePairingCode(pairingUrl);
    persist(credentialPath, JSON.stringify({ pairingUrl }));
  }
  connection = await openRemoteRuntimePassthroughSocket(pairedRuntimeConnectionFromOffer(pairing), capabilities, {
    onText: (text) => {
      const frame = JSON.parse(text);
      const request = pending.get(frame.id);
      if (!request) return;
      pending.delete(frame.id);
      clearTimeout(request.timer);
      if (frame.ok) request.resolve(frame.result);
      else request.reject(new Error('remote status unavailable'));
    },
    onBinary: () => {},
    onClose: close
  }, { timeoutMs: 15000 });
}
function probe(row) {
  return new Promise((resolve, reject) => {
    const id = randomUUID();
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('timeout')); }, 15000);
    pending.set(id, { resolve, reject, timer });
    void connection.send(JSON.stringify({
      id, method: 'status.get', params: {}, deviceToken: pairing.deviceToken,
      executionHost: `runtime:${row.id}`
    }));
  });
}
async function main() {
  mkdirSync(profile, { recursive: true, mode: 0o700 });
  // Serve has no renderer to keep main's remote-host status snapshots warm.
  // Use the released encrypted relay protocol, with a private local observer grant.
  const heartbeat = setInterval(() => {
    if (connection) persist(heartbeatPath, String(Date.now()));
  }, 5000);
  try {
    while (!stopped) {
      try {
        await hub.health();
        if (!connection) await open();
        persist(heartbeatPath, String(Date.now()));
        const queue = hub.list();
        await Promise.all(Array.from({ length: Math.min(4, queue.length) }, async () => {
          while (queue.length && connection && !stopped) {
            const row = queue.shift();
            await probe(row).catch(() => {});
          }
        }));
      } catch (error) {
        close();
        // Reissue only this local observer's revoked credential; phone grants stay unchanged.
        if (error.code === 'unauthorized') {
          pairing = null;
          persist(credentialPath, '{}');
        }
      }
      if (!stopped) await delay(5000);
    }
  } finally { clearInterval(heartbeat); close(); }
}
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => { stopped = true; close(); });
main().catch(() => { console.error('Hub status monitor exited; no credentials were printed.'); process.exitCode = 1; });
