'use strict';
const { join } = require('node:path');

class HubError extends Error {}

function checkServeConfig(config, port, required = false) {
  if (!/^[1-9][0-9]{0,4}$/.test(port) || Number(port) > 65535) throw new HubError('Invalid Serve port.');
  config ??= {};
  if (typeof config !== 'object' || Array.isArray(config)) throw new HubError('Invalid Serve configuration.');
  const configs = [config, ...Object.values(config.Foreground || {})];
  for (const entry of configs) {
    if (Object.entries(entry.AllowFunnel || {}).some(([key, enabled]) => enabled && key.endsWith(`:${port}`))) {
      throw new HubError('Funnel is enabled on the hub port. Disable that public exposure before continuing.');
    }
    const tcp = entry.TCP?.[port];
    if (tcp && (entry !== config || tcp.TCPForward !== `127.0.0.1:${port}` || tcp.HTTPS || tcp.HTTP || tcp.TerminateTLS || tcp.ProxyProtocol)) {
      throw new HubError('The gateway Serve port belongs to another service. Choose a different --port.');
    }
  }
  if (required && !config.TCP?.[port]) throw new HubError('The gateway TCP forwarder is missing.');
}

function desktopGatewayUrl(hubAddress, desktopPort) {
  if (!/^[1-9][0-9]{0,4}$/.test(String(desktopPort || '')) || Number(desktopPort) > 65535) {
    throw new HubError('Invalid desktop bridge port.');
  }
  let parsed;
  try { parsed = new URL(hubAddress); } catch { throw new HubError('Invalid ORCA_HUB_ADDRESS.'); }
  const protocol = parsed.protocol === 'wss:' ? 'https:' : parsed.protocol === 'ws:' ? 'http:' : null;
  if (!protocol || !parsed.hostname) throw new HubError('Invalid ORCA_HUB_ADDRESS.');
  const host = parsed.hostname.includes(':') ? `[${parsed.hostname}]` : parsed.hostname;
  return `${protocol}//${host}:${desktopPort}`;
}

function desktopEndpoint(hubAddress, desktopPort, nodeName) {
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$/.test(nodeName || '') || nodeName.toLowerCase() === 'local') {
    throw new HubError('Invalid node name for desktop endpoint.');
  }
  const base = desktopGatewayUrl(hubAddress, desktopPort);
  const wsBase = base.startsWith('https://') ? `wss://${base.slice(8)}` : `ws://${base.slice(7)}`;
  return `${wsBase}/node/${nodeName}`;
}

function createHub(app, profile) {
  // Use the pinned release's own pairing, encrypted transport and atomic store APIs.
  const out = join(app, 'resources/app.asar.unpacked/out');
  const native = (path) => require(join(out, path));
  const { RuntimeClient } = native('cli/runtime/client.js');
  const { parsePairingCode, encodePairingOffer } = native('shared/remote-runtime/pairing/pairing.js');
  const { exchangeCliPairingCode } = native('cli/runtime/environment-pairing-exchange.js');
  const store = native('shared/remote-runtime/host-store/runtime-environment-store.js');
  const { getPreferredPairingOffer } = native('shared/remote-runtime/host-catalog/runtime-environments.js');
  const client = () => new RuntimeClient(profile, 20000, null, null);
  const rows = () => store.listEnvironments(profile);
  const publicRow = (row) => ({ id: row.id, name: row.name, endpoint: getPreferredPairingOffer(row).endpoint });
  const sameKey = (a, b) => Buffer.from(a, 'base64').equals(Buffer.from(b, 'base64'));
  const status = async (remote) => (await remote.call('status.get')).result;
  const checkReady = (value) => {
    if (value.graphStatus !== 'ready') throw new HubError('Orca session graph is not ready.');
    if (!value.capabilities?.includes('pairing.delegated-mobile-devices.v1')) {
      throw new HubError('Update Orca: delegated mobile access is required.');
    }
    return value;
  };
  return {
    native,
    client,
    async health() {
      const value = checkReady(await status(client()));
      if (!value.capabilities?.includes('mobile.desktop-relay.v1')) {
        throw new HubError('Mobile relay is missing from this runtime.');
      }
      return { version: value.appVersion, runtimeId: value.runtimeId, ready: true };
    },
    list: () => rows().map(publicRow),
    nodeRow(name) {
      const row = rows().find((entry) => entry.name === name);
      return row ? publicRow(row) : null;
    },
    async mintDesktopOffer(name, response, gatewayEndpoint) {
      const row = rows().find((entry) => entry.name === name);
      if (!row) throw new HubError('No registered server with this name.');
      if (response?.ok !== true || response.result?.available !== true) {
        throw new HubError('Expected a successful Orca pairing JSON response on stdin.');
      }
      const code = response.result.pairingUrl;
      const offer = typeof code === 'string' ? parsePairingCode(code) : null;
      if (!offer || offer.scope !== 'runtime') throw new HubError('A runtime-scoped pairing offer is required.');
      const registeredOffer = getPreferredPairingOffer(row);
      if (!sameKey(registeredOffer.publicKeyB64, offer.publicKeyB64)) {
        throw new HubError('Pairing offer server identity does not match the registered hub node.');
      }
      // Activate and exchange over the container's direct private endpoint so the pending slot is freed
      // for additional Windows clients and the credential works immediately when claimed later.
      const internalCode = encodePairingOffer({ ...offer, endpoint: registeredOffer.endpoint });
      const exchangedInternal = await exchangeCliPairingCode(internalCode);
      const exchangedOffer = parsePairingCode(exchangedInternal);
      if (!exchangedOffer) throw new HubError('Failed to exchange desktop pairing ticket.');
      checkReady(await status(new RuntimeClient(profile, 15000, exchangedInternal, null)));
      const finalUrl = encodePairingOffer({ ...exchangedOffer, endpoint: gatewayEndpoint });
      return {
        nodeId: row.id,
        deviceId: typeof response.result.deviceId === 'string' ? response.result.deviceId : null,
        endpoint: gatewayEndpoint,
        pairingUrl: finalUrl
      };
    },
    async probe(name, endpoint) {
      const row = rows().find((entry) => entry.name === name);
      if (!row || getPreferredPairingOffer(row).endpoint !== endpoint) return false;
      const remote = new RuntimeClient(profile, 10000, null, row.id);
      checkReady(await status(remote));
      return true;
    },
    async register(name, response) {
      if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$/.test(name) || name.toLowerCase() === 'local') {
        throw new HubError('Use a unique 1-63 character server name other than local.');
      }
      if (response?.ok !== true || response.result?.available !== true) {
        throw new HubError('Expected a successful Orca pairing JSON response on stdin.');
      }
      const code = response.result.pairingUrl;
      const offer = typeof code === 'string' ? parsePairingCode(code) : null;
      if (!offer || offer.scope !== 'runtime') throw new HubError('A runtime-scoped pairing offer is required.');
      const named = rows().find((row) => row.name.toLowerCase() === name.toLowerCase());
      const keyed = rows().find((row) => sameKey(getPreferredPairingOffer(row).publicKeyB64, offer.publicKeyB64));
      if (named && (!keyed || named.id !== keyed.id)) {
        throw new HubError('This name belongs to another server identity. Remove its hub registration explicitly first.');
      }
      if (keyed && keyed.name !== name) throw new HubError('This server is already registered under another name.');
      if (keyed && await this.probe(name, offer.endpoint).catch(() => false)) return publicRow(keyed);
      await this.health();
      // Never save an unverified offline ticket as a successful enrollment.
      checkReady(await status(new RuntimeClient(profile, 15000, code, null)));
      const exchanged = await exchangeCliPairingCode(code);
      const remoteStatus = checkReady(await status(new RuntimeClient(profile, 15000, exchanged, null)));
      const row = keyed
        ? store.updateEnvironmentFromPairingCode(profile, keyed.id, { pairingCode: exchanged, runtimeId: remoteStatus.runtimeId })
        : store.addEnvironmentFromPairingCode(profile, { name, pairingCode: exchanged });
      // This records the remote runtime identity through the native CLI path.
      checkReady(await status(new RuntimeClient(profile, 15000, null, row.id)));
      // mobileRelay.hosts.* has a catalog only on authenticated WebSocket dispatch,
      // not the owner Unix socket. Exercise that path in the real mobile protocol test.
      return publicRow(row);
    },
    async pair(address) {
      await this.health();
      const response = await client().call('pairing.createOffer', { scope: 'mobile', address });
      if (!response.result.available) throw new HubError('Orca did not create a mobile pairing offer.');
      return response;
    },
    remove(name) {
      const row = rows().find((entry) => entry.name === name);
      if (!row) throw new HubError('No registered server with this name.');
      return publicRow(store.removeEnvironment(profile, row.id));
    }
  };
}

module.exports = { createHub, HubError, checkServeConfig, desktopEndpoint, desktopGatewayUrl };
