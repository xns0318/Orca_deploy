#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const root = process.env.HUB_FIXTURE;
if (!root) throw Error('Test fixture only');
const args = process.argv.slice(2);
fs.appendFileSync(path.join(root, 'commands.jsonl'), JSON.stringify(args) + '\n');
const file = path.join(root, 'state.json');
const state = JSON.parse(fs.readFileSync(file, 'utf8'));
const save = () => fs.writeFileSync(file, JSON.stringify(state));
const done = (value = '') => { if (value !== '') console.log(value); process.exit(0); };
const fail = () => process.exit(1);
const flag = (name) => args[args.indexOf(name) + 1];
const flags = (name) => args.flatMap((v, i) => v === name ? [args[i + 1]] : []);
const format = args.includes('--format') ? flag('--format') : '';
if (args[0] === 'context') done('unix:///var/run/docker.sock');
if (args[0] === 'version') done(format.includes('Arch') ? 'amd64' : 'linux');
if (args[0] === 'network' && args[1] === 'inspect') {
  if (format === '{{.Name}}') done(args.at(-1));
  if (format === '{{.Driver}}') done('bridge');
  if (format === '{{.Internal}}') done('false');
  if (format.includes('enable_icc')) done('true');
  if (format.includes('.IPAM.Config')) done('172.17.0.0/16');
}
if (args[0] === 'volume' && args[1] === 'inspect') {
  const volume = state.volumes[args.at(-1)];
  if (!volume) fail();
  if (!format) done(JSON.stringify(volume));
  done(process.env.HUB_FIXTURE_FOREIGN_VOLUME || volume.owner);
}
if (args[0] === 'volume' && args[1] === 'create') {
  state.volumes[args.at(-1)] ||= { owner: flag('--label').split('=')[1] };
  save(); done(args.at(-1));
}
if (args[0] === 'container' && args[1] === 'inspect') {
  const c = state.containers[args.at(-1)];
  if (!c) fail();
  if (!format) done(JSON.stringify(c));
  if (format === '{{.Id}}') done(c.id);
  if (format === '{{.Config.Image}}') done(c.image);
  if (format === '{{.HostConfig.NetworkMode}}') done(c.network);
  if (format === '{{.State.Running}}') done(c.running ? 'true' : 'false');
  if (format === '{{.State.Status}}') done(c.running ? 'running' : 'exited');
  if (format.includes('.State.Health')) done('healthy');
  if (format.includes('.Config.Labels')) {
    const key = format.match(/"([^"]+)"/)[1];
    done(process.env.HUB_FIXTURE_FOREIGN_HUB && c.id === 'hub-id' && key.endsWith('.role') ? 'unrelated' : c.labels[key]);
  }
  if (format.includes('.Mounts')) done(c.volume);
  if (format.includes('.NetworkSettings.Networks')) {
    done(Object.entries(c.networks).map(([name, ip]) => format.includes('IPAddress') ? `${name} ${ip}` : name).join('\n'));
  }
}
if (args[0] === 'image' && args[1] === 'inspect') {
  if (!state.images.includes(args.at(-1))) fail();
  if (format) {
    const m = state.imageMetadata[args.at(-1)];
    done(`${m.os} ${m.arch} ${m.fingerprint}`);
  }
  done('{}');
}
if (args[0] === 'build') {
  if (process.env.HUB_FIXTURE_BUILD_FAIL) fail();
  const image = flag('--tag');
  state.images.push(image);
  state.imageMetadata ||= {};
  state.imageMetadata[image] = { os: 'linux', arch: 'amd64', fingerprint: flag('--label').split('=')[1] };
  save(); done();
}
if (args[0] === 'image' && args[1] === 'save') {
  const image = args.at(-1);
  done(JSON.stringify({ image, metadata: state.imageMetadata[image] }));
}
if (args[0] === 'image' && args[1] === 'load') {
  const data = JSON.parse(require('node:zlib').gunzipSync(fs.readFileSync(flag('--input'))));
  state.images.push(data.image);
  state.imageMetadata ||= {};
  state.imageMetadata[data.image] = data.metadata;
  save(); done();
}
if (args[0] === 'create') {
  const name = flag('--name');
  if (state.containers[name]) fail();
  const labels = Object.fromEntries(flags('--label').map((v) => { const i = v.indexOf('='); return [v.slice(0, i), v.slice(i + 1)]; }));
  state.containers[name] = {
    id: 'hub-id', labels, image: args.at(-1), network: flag('--network'), networks: {}, running: false,
    volume: flag('--mount').match(/src=([^,]+)/)[1]
  };
  save(); done('hub-id');
}
if (args[0] === 'start' || args[0] === 'stop') {
  state.containers[args.at(-1)].running = args[0] === 'start'; save(); done();
}
if (args[0] === 'rm') { delete state.containers[args.at(-1)]; save(); done(); }
if (args[0] === 'exec') {
  let i = 1;
  while (args[i]?.startsWith('-')) i += ['--user', '--env'].includes(args[i]) ? 2 : 1;
  const container = args[i++];
  const cmd = args.slice(i);
  if (container === 'orca-gateway') {
    if (cmd.join(' ') === 'tailscale ip -4') done('100.92.0.8');
    if (cmd.join(' ') === 'tailscale serve status --json') done(JSON.stringify(state.serve));
    if (cmd[1] === 'serve' && cmd.includes('--bg')) {
      const port = cmd.find((v) => v.startsWith('--tcp=')).slice(6);
      state.serve.TCP ||= {};
      state.serve.TCP[port] = { TCPForward: `127.0.0.1:${port}` };
      save(); done();
    }
  }
  if (container === 'orca-hub') {
    if (cmd[0] !== 'hubctl') throw Error('Unexpected hub command');
    if (cmd[1] === 'health') { if (process.env.HUB_FIXTURE_UNHEALTHY) fail(); done(); }
    if (cmd[1] === 'name') done();
    if (cmd[1] === 'check-serve') { fs.readFileSync(0); if (process.env.HUB_FIXTURE_CONFLICT) fail(); done(); }
    if (cmd[1] === 'probe') { if (!state.registered?.[cmd[2]]) process.exit(3); done(); }
    if (cmd[1] === 'register') {
      const input = JSON.parse(fs.readFileSync(0, 'utf8'));
      if (input.result.pairingUrl !== 'orca://pair?TEST_ONLY_PRIVATE_OFFER') throw Error('Missing private enrollment input');
      state.registered ||= {};
      state.registered[cmd[2]] = true; save(); done('Registered');
    }
  }
  if (container === 'agent-one') {
    if (cmd[0] === 'sh') done('/root');
    if (cmd[0] === 'test') { if (!state.agentInstalled) fail(); done(); }
    if (cmd[0] === 'mktemp') done('/tmp/orca-enroll.fixture');
    if (cmd[0] === 'rm') done();
    if (cmd[0] === 'tar') { fs.readFileSync(0); done(); }
    if (cmd[0] === 'bash' && cmd[2].startsWith('source')) done('6768');
    if (cmd[0] === 'bash') { state.agentInstalled = true; save(); done(); }
    if (cmd[0].endsWith('/orca-service')) done(JSON.stringify({ ok: true, result: { available: true, pairingUrl: 'orca://pair?TEST_ONLY_PRIVATE_OFFER' } }));
  }
}
throw Error(`Unexpected fixture command: ${JSON.stringify(args)}`);
