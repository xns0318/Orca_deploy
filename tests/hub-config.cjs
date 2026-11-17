const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { resolve, join } = require('node:path');
const { mkdtempSync, symlinkSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { checkServeConfig } = require('../hub/orca-api.cjs');

test('Serve leaves unrelated private listeners alone and accepts only the exact hub forwarder', () => {
  for (const config of [null, {}, { TCP: { 443: { HTTPS: true } } }]) {
    assert.doesNotThrow(() => checkServeConfig(config, '6768'));
  }
  assert.doesNotThrow(() => checkServeConfig({ TCP: { 6768: { TCPForward: '127.0.0.1:6768' } } }, '6768', true));
  assert.throws(() => checkServeConfig({}, '6768', true), /missing/);
  for (const handler of [{ HTTPS: true }, { TCPForward: '127.0.0.1:22' },
    { TCPForward: '127.0.0.1:6768', TerminateTLS: 'example.test' },
    { TCPForward: '127.0.0.1:6768', ProxyProtocol: 2 }]) {
    assert.throws(() => checkServeConfig({ TCP: { 6768: handler } }, '6768'), /another service/);
  }
});
test('Serve refuses public Funnel and foreground port ownership', () => {
  assert.throws(() => checkServeConfig({ AllowFunnel: { 'gateway.example:6768': true } }, '6768'), /Funnel/);
  assert.throws(() => checkServeConfig({ Foreground: { session: { TCP: { 6768: { TCPForward: '127.0.0.1:6768' } } } } }, '6768'), /another service/);
  assert.throws(() => checkServeConfig({ Foreground: { session: { AllowFunnel: { 'gateway.example:6768': true } } } }, '6768'), /Funnel/);
  assert.doesNotThrow(() => checkServeConfig({ AllowFunnel: { 'other.example:443': true } }, '6768'));
});
test('invalid config and port are refused, and parser errors do not echo secret input', () => {
  for (const port of ['0', '-1', '65536', 'abc', undefined]) assert.throws(() => checkServeConfig({}, port));
  for (const config of [[], false, 'bad']) assert.throws(() => checkServeConfig(config, '6768'));
  const result = spawnSync(process.execPath, [resolve(__dirname, '../hub/hubctl.cjs'), 'check-serve', '6768'], {
    input: 'TEST_PRIVATE_KEY invalid JSON', encoding: 'utf8'
  });
  assert.equal(result.status, 1);
  assert(!`${result.stdout}${result.stderr}`.includes('TEST_PRIVATE_KEY'));
});

test('hubctl resolves its module directory when invoked through an installed symlink', () => {
  const dir = mkdtempSync(join(tmpdir(), 'orca hubctl '));
  try {
    symlinkSync(process.execPath, join(dir, 'orca-ide'));
    symlinkSync(resolve(__dirname, '../hub/hubctl'), join(dir, 'hubctl'));
    const result = spawnSync('bash', [join(dir, 'hubctl'), 'check-serve', '6768'], {
      input: '{}', encoding: 'utf8',
      env: { ...process.env, HOME: dir, ORCA_HUB_APP: dir }
    });
    assert.equal(result.status, 0, result.stderr);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
