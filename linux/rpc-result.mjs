import { readFileSync } from 'node:fs';

try {
  const mode = process.argv[2];
  if (mode === 'address') {
    const address = new URL(process.argv[3]);
    if (!['ws:', 'wss:'].includes(address.protocol) || !address.hostname ||
        address.username || address.password || address.search || address.hash ||
        !['', '/'].includes(address.pathname)) {
      throw new Error('Use a ws://host:port or wss://host:port endpoint without a path or credentials.');
    }
    process.exit(0);
  }
  const response = JSON.parse(readFileSync(0, 'utf8'));
  if (response.ok !== true || !response.result) throw new Error('Orca RPC did not succeed.');
  if (mode === 'pair') {
    if (response.result.available !== true ||
        typeof response.result.pairingUrl !== 'string' ||
        !response.result.pairingUrl.startsWith('orca://pair?')) {
      throw new Error('Orca did not return an available pairing offer.');
    }
    process.stdout.write(JSON.stringify(response, null, 2) + '\n');
  } else if (mode !== 'status') {
    throw new Error('Unknown response check.');
  }
} catch (error) {
  // Do not echo RPC bodies: pairing responses contain credentials.
  console.error(error instanceof SyntaxError ? 'Invalid JSON from Orca.' : error.message);
  process.exit(1);
}
