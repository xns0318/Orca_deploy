#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const args = process.argv.slice(2);
if (args[0] === '--version') {
  console.log('1.4.271');
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
  const readyAt = Date.now() + Number(process.env.FIXTURE_START_DELAY_MS || 0);
  writeFileSync(ready, JSON.stringify({ pid: process.pid, args, readyAt }));
  const stop = () => { rmSync(ready, { force: true }); process.exit(0); };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
  setInterval(() => {}, 60000);
} else {
  const server = existsSync(ready) ? JSON.parse(readFileSync(ready, 'utf8')) : null;
  let reachable = Boolean(server) && !existsSync(join(state, 'fail-health')) && Date.now() >= server.readyAt;
  if (server) { try { process.kill(server.pid, 0); } catch { reachable = false; } }
  if (args[0] === 'status') {
    reply({
      app: { running: reachable, pid: reachable ? server.pid : null },
      runtime: { reachable, state: reachable ? 'ready' : 'not_running' },
      graph: { state: reachable ? 'ready' : 'not_running' },
    });
    process.exit(0);
  }
  if (!reachable) process.exit(2);
  if (args[0] === 'host' && args[1] === 'name') {
    writeFileSync(join(state, 'fixture-name'), argument('--name'));
    reply({ name: argument('--name') });
  } else if (args[0] === 'pair') {
    reply({ available: true, pairingUrl: 'orca://pair?code=TEST_PRIVATE_OFFER', endpoint: argument('--address') });
  } else process.exit(3);
}
