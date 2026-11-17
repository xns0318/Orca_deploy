#!/usr/bin/env node
'use strict';
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { createHub, HubError, checkServeConfig } = require('./orca-api.cjs');

async function main() {
  const [action = 'status', ...args] = process.argv.slice(2);
  if (action === 'check-serve') {
    checkServeConfig(JSON.parse(readFileSync(0, 'utf8')), args[0], args[1] === '--required');
    return;
  }
  const hub = createHub(process.env.ORCA_HUB_APP || '/opt/Orca', process.env.ORCA_USER_DATA_PATH);
  const print = (value) => console.log(JSON.stringify(value, null, 2));
  async function health() {
    const runtime = await hub.health();
    let observerReady = false;
    try {
      const last = Number(readFileSync(join(process.env.ORCA_USER_DATA_PATH, 'hub-monitor.heartbeat'), 'utf8'));
      observerReady = Number.isFinite(last) && Date.now() - last < 30000;
    } catch {}
    if (process.env.ORCA_HUB_REQUIRE_MONITOR === '1' && !observerReady) throw new HubError('Hub status monitor is not ready.');
    return { ...runtime, observerReady };
  }
  switch (action) {
    case 'health': await health(); break;
    case 'status': print({ ...await health(), servers: hub.list() }); break;
    case 'list': print(hub.list()); break;
    case 'name': await hub.client().call('settings.update', { machineName: args[0] }); break;
    case 'probe': process.exitCode = await hub.probe(args[0], args[1]) ? 0 : 3; break;
    case 'register': {
      const input = readFileSync(0, 'utf8');
      if (input.length > 65536) throw new HubError('Pairing input exceeds 64 KiB.');
      print(await hub.register(args[0] || '', JSON.parse(input)));
      break;
    }
    case 'remove': print(hub.remove(args[0])); break;
    case 'pair': {
      const response = await hub.pair(process.env.ORCA_HUB_ADDRESS);
      if (args[0] === '--json') print(response);
      else {
        console.log(response.result.qr || '');
        console.log(response.result.pairingUrl);
      }
      break;
    }
    default: throw new HubError('Usage: hubctl {status|list|pair [--json]|register NAME|remove NAME}');
  }
}
main().catch((error) => {
  // Native errors and input can contain credentials. Never print their bodies or stacks.
  const code = typeof error.code === 'string' && /^[a-zA-Z0-9_-]{1,80}$/.test(error.code) ? ` (${error.code})` : '';
  console.error(error instanceof HubError ? error.message : `Orca hub operation failed${code}. Check connectivity and the service logs; credentials were not printed.`);
  process.exitCode = 1;
});
