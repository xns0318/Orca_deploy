#!/usr/bin/env node
import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const root = process.env.GATEWAY_FIXTURE;
if (!root) throw new Error('This Docker fixture is for tests only.');
const args = process.argv.slice(2);
appendFileSync(join(root, 'commands.jsonl'), JSON.stringify(args) + '\n');
const stateFile = join(root, 'state.json');
const state = existsSync(stateFile) ? JSON.parse(readFileSync(stateFile, 'utf8')) : {};
const save = () => writeFileSync(stateFile, JSON.stringify(state));
const flag = (name) => args[args.indexOf(name) + 1];
const flags = (name) => args.flatMap((value, index) => value === name ? [args[index + 1]] : []);
const result = (value) => { console.log(value); process.exit(0); };
const missing = () => process.exit(1);
const format = args.includes('--format') ? flag('--format') : '';

if (args[0] === 'context') result(process.env.FIXTURE_DOCKER_ENDPOINT || 'unix:///var/run/docker.sock');
if (args[0] === 'version') result('linux');
if (args[0] === 'network' && args[1] === 'inspect') {
  const network = args.at(-1);
  if (!['bridge', 'agents'].includes(network)) missing();
  if (format === '{{.Name}}') result(network);
  if (format === '{{.Driver}}') result(process.env.FIXTURE_DRIVER || 'bridge');
  if (format === '{{.Internal}}') result(process.env.FIXTURE_INTERNAL || 'false');
  if (format.includes('enable_icc')) result(process.env.FIXTURE_ICC || '<no value>');
  if (format.includes('.IPAM.Config')) {
    result(process.env.FIXTURE_SUBNET || (network === 'bridge' ? '172.17.0.0/16' : '10.88.0.0/24'));
  }
}
if (args[0] === 'volume' && args[1] === 'inspect') {
  if (!state.volume) missing();
  if (!format) result(JSON.stringify(state.volume));
  if (format.includes('com.orca-deploy.gateway')) result(process.env.FIXTURE_VOLUME_OWNER || state.volume.owner);
}
if (args[0] === 'volume' && args[1] === 'create') {
  state.volume ||= { name: args.at(-1), owner: flag('--label').split('=')[1] };
  save();
  result(state.volume.name);
}
if (args[0] === 'pull') result('Fixture image available');
if (args[0] === 'create') {
  if (state.container) missing();
  const labels = Object.fromEntries(flags('--label').map(value => value.split('=')));
  const mounts = flags('--mount').map(value => Object.fromEntries(value.split(',').map(field => {
    const [key, ...rest] = field.split('=');
    return [key, rest.join('=')];
  })));
  state.container = {
    name: flag('--name'), labels, mounts, image: args.at(-1),
    primaryNetwork: flag('--network'), networks: [flag('--network')], status: 'created'
  };
  save();
  result('fixture-container-id');
}
if (args[0] === 'container' && args[1] === 'inspect') {
  const container = state.container;
  if (!container) missing();
  if (!format) result(JSON.stringify(container));
  if (format === '{{.Config.Image}}') result(container.image);
  if (format === '{{.HostConfig.NetworkMode}}') result(container.primaryNetwork);
  if (format.includes('.Config.Labels')) {
    const key = format.match(/"([^"]+)"/)[1];
    result(key === 'com.orca-deploy.role' && process.env.FIXTURE_CONTAINER_OWNER || container.labels[key]);
  }
  if (format.includes('.Mounts')) {
    if (format.includes('/run/secrets/tailscale-authkey')) result(container.mounts.find(m => m.dst === '/run/secrets/tailscale-authkey').src);
    if (format.includes('/var/lib/tailscale')) result(container.mounts.find(m => m.dst === '/var/lib/tailscale').src);
  }
  if (format.includes('.NetworkSettings.Networks')) result(container.networks.join('\n'));
  if (format === '{{.State.Running}}') result(container.status === 'running' ? 'true' : 'false');
  if (format === '{{.State.Status}}') result(container.status);
  if (format.includes('.State.Health')) result(process.env.FIXTURE_HEALTH || 'healthy');
}
if (args[0] === 'start') {
  if (!state.bootstrapCopied) throw new Error('Gateway started before its private bootstrap key was copied');
  state.container.status = 'running';
  save();
  result(state.container.name);
}
if (args[0] === 'cp') {
  if (process.env.FIXTURE_COPY_FAIL) process.exit(7);
  if (args[2] !== 'orca-gateway:/var/lib/tailscale/bootstrap.authkey') throw new Error('Unexpected credential destination');
  if (!existsSync(args[1])) throw new Error('Missing credential source');
  state.bootstrapCopied = true;
  save();
  process.exit(0);
}
if (args[0] === 'network' && args[1] === 'connect') {
  if (state.container.networks.includes(args[2])) throw new Error('Duplicate network attachment');
  state.container.networks.push(args[2]);
  save();
  process.exit(0);
}
if (args[0] === 'exec' && args.slice(2).join(' ') === 'tailscale ip -4') result('100.92.0.8');
throw new Error(`Unexpected fixture Docker command: ${JSON.stringify(args)}`);
