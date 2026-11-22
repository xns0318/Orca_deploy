#!/usr/bin/env node
'use strict';
const http = require('node:http');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { createHub, HubError, checkServeConfig, desktopEndpoint, desktopGatewayUrl } = require('./orca-api.cjs');
const { createBridgeStore, BridgeError } = require('./bridge-store.cjs');

function probeBridgeHealth(port) {
  return new Promise((resolve) => {
    const req = http.get({ host: '127.0.0.1', port: Number(port), path: '/healthz', timeout: 3000 }, (res) => {
      res.resume();
      resolve(res.statusCode === 200);
    });
    req.on('error', () => resolve(false));
    req.on('timeout', () => { req.destroy(); resolve(false); });
  });
}

async function main() {
  const [action = 'status', ...args] = process.argv.slice(2);
  if (action === 'check-serve') {
    checkServeConfig(JSON.parse(readFileSync(0, 'utf8')), args[0], args[1] === '--required');
    return;
  }
  const profile = process.env.ORCA_USER_DATA_PATH;
  const hubAddress = process.env.ORCA_HUB_ADDRESS || `ws://127.0.0.1:${process.env.ORCA_HUB_PORT || '6768'}`;
  const desktopPort = process.env.ORCA_DESKTOP_PORT || '6769';
  const print = (value) => console.log(JSON.stringify(value, null, 2));

  if (action === 'desktop-endpoint') {
    console.log(desktopEndpoint(hubAddress, desktopPort, args[0]));
    return;
  }

  const bridge = createBridgeStore(profile);
  if (action === 'client') {
    const [sub, name] = args;
    switch (sub) {
      case 'add': {
        const created = bridge.addClient(name);
        const gatewayUrl = desktopGatewayUrl(hubAddress, desktopPort);
        print({
          ...created,
          gatewayUrl,
          syncCommand: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\windows\\Sync.ps1 -Gateway ${gatewayUrl} -Token ${created.token} -InstallTask`
        });
        return;
      }
      case 'list': {
        if (name === '--active-names') {
          for (const clientName of bridge.activeClientNames()) console.log(clientName);
        } else {
          print(bridge.listClients());
        }
        return;
      }
      case 'revoke': {
        print(bridge.revokeClient(name));
        return;
      }
      default:
        throw new HubError('Usage: hubctl client {add NAME|list [--active-names]|revoke NAME}');
    }
  }

  const hub = createHub(process.env.ORCA_HUB_APP || '/opt/Orca', profile);
  async function health() {
    const runtime = await hub.health();
    let observerReady = false;
    try {
      const last = Number(readFileSync(join(profile, 'hub-monitor.heartbeat'), 'utf8'));
      observerReady = Number.isFinite(last) && Date.now() - last < 30000;
    } catch {}
    if (process.env.ORCA_HUB_REQUIRE_MONITOR === '1' && !observerReady) {
      throw new HubError('Hub status monitor is not ready.');
    }
    const bridgeReady = await probeBridgeHealth(desktopPort);
    if (process.env.ORCA_HUB_REQUIRE_BRIDGE === '1' && !bridgeReady) {
      throw new HubError('Desktop gateway bridge is not ready.');
    }
    return { ...runtime, observerReady, bridgeReady, desktopPort: Number(desktopPort) };
  }

  switch (action) {
    case 'health': await health(); break;
    case 'status': print({ ...await health(), servers: hub.list(), desktopClients: bridge.listClients() }); break;
    case 'list': print(hub.list()); break;
    case 'name': await hub.client().call('settings.update', { machineName: args[0] }); break;
    case 'probe': process.exitCode = await hub.probe(args[0], args[1]) ? 0 : 3; break;
    case 'register': {
      const input = readFileSync(0, 'utf8');
      if (input.length > 65536) throw new HubError('Pairing input exceeds 64 KiB.');
      print(await hub.register(args[0] || '', JSON.parse(input)));
      break;
    }
    case 'remove': {
      const removed = hub.remove(args[0]);
      bridge.removeNode(args[0]);
      print(removed);
      break;
    }
    case 'offer-needed': {
      const [clientName, nodeName] = args;
      const row = hub.nodeRow(nodeName);
      if (!row) throw new HubError('No registered server with this name.');
      process.exitCode = bridge.hasValidGrant(clientName, nodeName, row.id) ? 3 : 0;
      break;
    }
    case 'offer-put': {
      const [clientName, nodeName] = args;
      const input = readFileSync(0, 'utf8');
      if (input.length > 65536) throw new HubError('Pairing input exceeds 64 KiB.');
      const gatewayEndpoint = desktopEndpoint(hubAddress, desktopPort, nodeName);
      const minted = await hub.mintDesktopOffer(nodeName, JSON.parse(input), gatewayEndpoint);
      const stored = bridge.putOffer({
        client: clientName,
        node: nodeName,
        nodeId: minted.nodeId,
        deviceId: minted.deviceId,
        endpoint: minted.endpoint,
        pairingUrl: minted.pairingUrl
      });
      print(stored);
      break;
    }
    case 'pair': {
      const response = await hub.pair(hubAddress);
      if (args[0] === '--json') print(response);
      else {
        console.log(response.result.qr || '');
        console.log(response.result.pairingUrl);
      }
      break;
    }
    default:
      throw new HubError('Usage: hubctl {status|list|pair [--json]|register NAME|remove NAME|client ...|offer-put CLIENT NODE|offer-needed CLIENT NODE|desktop-endpoint NODE}');
  }
}

main().catch((error) => {
  // Native errors and input can contain credentials. Never print their bodies or stacks.
  const code = typeof error.code === 'string' && /^[a-zA-Z0-9_-]{1,80}$/.test(error.code) ? ` (${error.code})` : '';
  const safe = error instanceof HubError || error instanceof BridgeError;
  console.error(safe ? error.message : `Orca hub operation failed${code}. Check connectivity and the service logs; credentials were not printed.`);
  process.exitCode = 1;
});
