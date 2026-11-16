#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const args = process.argv.slice(2);
if (args[0] === '--version') {
  console.log('1.4.259');
  process.exit(0);
}
if (process.env.ORCA_ENVIRONMENT || process.env.ORCA_REMOTE_PAIRING || process.env.ORCA_PAIRING_CODE) {
  console.error('Unexpected ambient routing override');
  process.exit(98);
}
const state = process.env.ORCA_USER_DATA_PATH;
mkdirSync(state, { recursive: true });
const ready = join(state, 'fixture-server.json');
const argument = (key) => args[args.indexOf(key) + 1];
const reply = (result) => console.log(JSON.stringify({ ok: true, result }));
if (args[0] === 'serve') {
  writeFileSync(ready, JSON.stringify({ pid: process.pid, args }));
  const stop = () => { rmSync(ready, { force: true }); process.exit(0); };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
  setInterval(() => {}, 60000);
} else {
  if (!existsSync(ready) || existsSync(join(state, 'fail-health'))) process.exit(2);
  const server = JSON.parse(readFileSync(ready, 'utf8'));
  try { process.kill(server.pid, 0); } catch { process.exit(2); }
  if (args[0] === 'status') reply({ healthy: true });
  else if (args[0] === 'host' && args[1] === 'name') {
    writeFileSync(join(state, 'fixture-name'), argument('--name'));
    reply({ name: argument('--name') });
  } else if (args[0] === 'pair') {
    reply({ available: true, pairingUrl: 'orca://pair?code=TEST_PRIVATE_OFFER', endpoint: argument('--address') });
  } else process.exit(3);
}
