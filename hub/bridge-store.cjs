'use strict';
const {
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync
} = require('node:fs');
const { join } = require('node:path');
const { createHash, randomBytes, timingSafeEqual } = require('node:crypto');

const NAME_RE = /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$/;
const STALE_LOCK_MS = 30000;
const LOCK_TIMEOUT_MS = 10000;

class BridgeError extends Error {}

function assertValidClientName(name) {
  if (typeof name !== 'string' || !NAME_RE.test(name)) {
    throw new BridgeError('Use a unique 1-63 character Windows client name (letters, digits, dot, underscore, hyphen).');
  }
}

function assertValidNodeName(name) {
  if (typeof name !== 'string' || !NAME_RE.test(name) || name.toLowerCase() === 'local') {
    throw new BridgeError('Use a valid 1-63 character node name other than local.');
  }
}

function hashToken(token) {
  return createHash('sha256').update(token, 'utf8').digest('hex');
}

function hashesMatch(hexA, hexB) {
  if (typeof hexA !== 'string' || typeof hexB !== 'string' || hexA.length !== 64 || hexB.length !== 64) {
    return false;
  }
  const a = Buffer.from(hexA, 'hex');
  const b = Buffer.from(hexB, 'hex');
  return a.length === 32 && b.length === 32 && timingSafeEqual(a, b);
}

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function acquireLock(lockPath) {
  const deadline = Date.now() + LOCK_TIMEOUT_MS;
  while (true) {
    try {
      const fd = openSync(lockPath, 'wx', 0o600);
      try {
        writeFileSync(fd, `${process.pid} ${Date.now()}\n`);
      } finally {
        closeSync(fd);
      }
      return () => {
        try { unlinkSync(lockPath); } catch {}
      };
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      try {
        const st = statSync(lockPath);
        if (Date.now() - st.mtimeMs > STALE_LOCK_MS) {
          unlinkSync(lockPath);
          continue;
        }
      } catch {}
      if (Date.now() >= deadline) {
        throw new BridgeError('Timed out waiting for the Windows bridge state lock.');
      }
      sleepSync(15);
    }
  }
}

function normalizeState(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    return { version: 1, clients: {}, grants: {} };
  }
  return {
    version: 1,
    clients: raw.clients && typeof raw.clients === 'object' && !Array.isArray(raw.clients) ? raw.clients : {},
    grants: raw.grants && typeof raw.grants === 'object' && !Array.isArray(raw.grants) ? raw.grants : {}
  };
}

function atomicWriteJson(filePath, value) {
  const tmp = `${filePath}.${process.pid}.${randomBytes(6).toString('hex')}.tmp`;
  writeFileSync(tmp, JSON.stringify(value, null, 2) + '\n', { mode: 0o600 });
  renameSync(tmp, filePath);
}

function createBridgeStore(profile) {
  if (!profile) throw new BridgeError('ORCA_USER_DATA_PATH is required.');
  const statePath = join(profile, 'windows-bridge.json');
  const seenPath = join(profile, 'windows-bridge-seen.json');
  const lockPath = join(profile, '.windows-bridge.lock');

  const ensureDir = () => mkdirSync(profile, { recursive: true, mode: 0o700 });

  const readJson = (filePath) => {
    if (!existsSync(filePath)) return null;
    return JSON.parse(readFileSync(filePath, 'utf8'));
  };

  const load = () => normalizeState(readJson(statePath));
  const loadSeen = () => {
    try {
      const parsed = readJson(seenPath);
      return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
    } catch {
      return {};
    }
  };

  const withLock = (fn) => {
    ensureDir();
    const release = acquireLock(lockPath);
    try {
      return fn();
    } finally {
      release();
    }
  };

  return {
    statePath,
    load,
    addClient(name) {
      assertValidClientName(name);
      return withLock(() => {
        const state = load();
        const existing = Object.keys(state.clients).find((key) => key.toLowerCase() === name.toLowerCase());
        if (existing) {
          throw new BridgeError(`Windows client '${existing}' already exists. Choose a new client name.`);
        }
        const token = `orca_win_${randomBytes(32).toString('hex')}`;
        const createdAt = Date.now();
        state.clients[name] = {
          tokenHash: hashToken(token),
          createdAt,
          revokedAt: null
        };
        state.grants[name] = {};
        atomicWriteJson(statePath, state);
        return { name, token, createdAt };
      });
    },
    listClients() {
      const state = load();
      const seen = loadSeen();
      return Object.entries(state.clients)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([name, entry]) => {
          const clientGrants = state.grants[name] || {};
          const values = Object.values(clientGrants);
          return {
            name,
            status: entry.revokedAt ? 'revoked' : 'active',
            createdAt: entry.createdAt || null,
            revokedAt: entry.revokedAt || null,
            lastSeenAt: typeof seen[name] === 'number' ? seen[name] : null,
            pendingNodes: values.filter((g) => g && g.status === 'pending' && g.pairingUrl).length,
            claimedNodes: values.filter((g) => g && g.status === 'claimed').length
          };
        });
    },
    activeClientNames() {
      const state = load();
      return Object.entries(state.clients)
        .filter(([, entry]) => entry && !entry.revokedAt)
        .map(([name]) => name)
        .sort((a, b) => a.localeCompare(b));
    },
    revokeClient(name) {
      assertValidClientName(name);
      return withLock(() => {
        const state = load();
        const client = state.clients[name];
        if (!client) throw new BridgeError(`No Windows client named '${name}'.`);
        const revokedAt = client.revokedAt || Date.now();
        client.revokedAt = revokedAt;
        const clientGrants = state.grants[name] || {};
        const devices = [];
        for (const [node, grant] of Object.entries(clientGrants)) {
          if (!grant) continue;
          if (grant.deviceId) {
            devices.push({ node, nodeId: grant.nodeId || null, deviceId: grant.deviceId });
          }
          grant.pairingUrl = null;
          if (grant.status === 'pending') grant.status = 'revoked';
          grant.updatedAt = revokedAt;
        }
        atomicWriteJson(statePath, state);
        return { name, revokedAt, devices };
      });
    },
    authenticate(authHeader) {
      if (typeof authHeader !== 'string') return null;
      const match = /^Bearer\s+([A-Za-z0-9._-]{20,256})$/.exec(authHeader.trim());
      if (!match) return null;
      const presentedHash = hashToken(match[1]);
      const state = load();
      let matched = null;
      for (const [name, entry] of Object.entries(state.clients)) {
        if (!entry || entry.revokedAt || typeof entry.tokenHash !== 'string') continue;
        if (hashesMatch(entry.tokenHash, presentedHash)) {
          matched = name;
        }
      }
      return matched;
    },
    touchClient(name) {
      const now = Date.now();
      const seen = loadSeen();
      if (typeof seen[name] === 'number' && now - seen[name] < 60000) return;
      ensureDir();
      seen[name] = now;
      try { atomicWriteJson(seenPath, seen); } catch {}
    },
    putOffer({ client, node, nodeId, deviceId, endpoint, pairingUrl }) {
      assertValidClientName(client);
      assertValidNodeName(node);
      if (typeof nodeId !== 'string' || !nodeId) throw new BridgeError('Missing nodeId.');
      if (typeof endpoint !== 'string' || !endpoint) throw new BridgeError('Missing endpoint.');
      if (typeof pairingUrl !== 'string' || !pairingUrl.startsWith('orca://pair?code=')) {
        throw new BridgeError('Invalid pairingUrl.');
      }
      return withLock(() => {
        const state = load();
        const entry = state.clients[client];
        if (!entry || entry.revokedAt) {
          throw new BridgeError(`Windows client '${client}' is not active.`);
        }
        state.grants[client] ||= {};
        const updatedAt = Date.now();
        state.grants[client][node] = {
          nodeId,
          deviceId: deviceId || null,
          endpoint,
          pairingUrl,
          status: 'pending',
          updatedAt
        };
        atomicWriteJson(statePath, state);
        return { client, node, nodeId, deviceId: deviceId || null, endpoint, status: 'pending', updatedAt };
      });
    },
    hasValidGrant(client, node, nodeId) {
      const state = load();
      const entry = state.clients[client];
      if (!entry || entry.revokedAt) return false;
      const grant = state.grants[client]?.[node];
      if (!grant || grant.nodeId !== nodeId) return false;
      return grant.status === 'claimed' || (grant.status === 'pending' && typeof grant.pairingUrl === 'string' && grant.pairingUrl.length > 0);
    },
    stateForClient(client, currentNodes, desktopEndpointFor) {
      const state = load();
      const clientGrants = state.grants[client] || {};
      return currentNodes.map((node) => {
        const grant = clientGrants[node.name];
        const endpoint = desktopEndpointFor(node.name);
        let grantStatus = 'unprovisioned';
        if (grant && grant.nodeId === node.id) {
          if (grant.status === 'pending' && typeof grant.pairingUrl === 'string' && grant.pairingUrl.length > 0) {
            grantStatus = 'pending';
          } else if (grant.status === 'claimed') {
            grantStatus = 'claimed';
          }
        }
        return {
          name: node.name,
          nodeId: node.id,
          endpoint: grant && grant.nodeId === node.id && grant.endpoint ? grant.endpoint : endpoint,
          grantStatus
        };
      });
    },
    claimOffer(client, node, currentNodesByName) {
      assertValidClientName(client);
      assertValidNodeName(node);
      const current = currentNodesByName.get(node);
      if (!current) return { ok: false, statusCode: 404, error: 'node_not_found' };
      const state = load();
      const entry = state.clients[client];
      if (!entry || entry.revokedAt) return { ok: false, statusCode: 401, error: 'unauthorized' };
      const grant = state.grants[client]?.[node];
      if (!grant || grant.nodeId !== current.id || grant.status !== 'pending' || !grant.pairingUrl) {
        return { ok: false, statusCode: 404, error: 'offer_unavailable' };
      }
      return {
        ok: true,
        offer: {
          name: node,
          nodeId: grant.nodeId,
          endpoint: grant.endpoint,
          pairingUrl: grant.pairingUrl
        }
      };
    },
    ackOffer(client, node, nodeId) {
      assertValidClientName(client);
      assertValidNodeName(node);
      return withLock(() => {
        const state = load();
        const entry = state.clients[client];
        if (!entry || entry.revokedAt) return { ok: false, statusCode: 401, error: 'unauthorized' };
        const grant = state.grants[client]?.[node];
        if (!grant) return { ok: false, statusCode: 404, error: 'grant_not_found' };
        if (nodeId && grant.nodeId !== nodeId) return { ok: false, statusCode: 409, error: 'node_id_mismatch' };
        grant.pairingUrl = null;
        grant.status = 'claimed';
        grant.claimedAt = Date.now();
        grant.updatedAt = grant.claimedAt;
        atomicWriteJson(statePath, state);
        return { ok: true, node, nodeId: grant.nodeId, status: 'claimed' };
      });
    },
    removeNode(node) {
      assertValidNodeName(node);
      return withLock(() => {
        const state = load();
        let removed = 0;
        for (const clientGrants of Object.values(state.grants)) {
          if (clientGrants && Object.prototype.hasOwnProperty.call(clientGrants, node)) {
            delete clientGrants[node];
            removed++;
          }
        }
        if (removed > 0) atomicWriteJson(statePath, state);
        return removed;
      });
    }
  };
}

module.exports = {
  BridgeError,
  NAME_RE,
  assertValidClientName,
  assertValidNodeName,
  hashToken,
  createBridgeStore
};
