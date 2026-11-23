#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/linux/common.sh"

target=${1:-}
[[ -n "$target" ]] || fail 'Usage: bash hub/bump-version.sh <VERSION|latest>  (e.g. 1.4.271 or latest)'
require_commands curl node
if [[ "$target" == latest ]]; then
  api_url='https://api.github.com/repos/stablyai/orca/releases/latest'
else
  target=${target#v}
  [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid version: $target"
  api_url="https://api.github.com/repos/stablyai/orca/releases/tags/v$target"
fi

lock_file="$ROOT/versions.lock.env"
curl -fsSL --connect-timeout 15 --max-time 30 "$api_url" | node - "$lock_file" <<'NODE'
'use strict';
const fs = require('node:fs');
const lockFile = process.argv[2];
const release = JSON.parse(fs.readFileSync(0, 'utf8'));
const tag = String(release.tag_name || '');
const m = /^v([0-9]+\.[0-9]+\.[0-9]+)$/.exec(tag);
if (!m) throw new Error(`Unexpected release tag: ${tag}`);
const version = m[1];
const want = {
  LINUX_X64: 'orca-server-linux-x64.tar.gz',
  LINUX_ARM64: 'orca-server-linux-arm64.tar.gz',
  WINDOWS_X64: 'orca-windows-setup.exe',
  HUB_X64: `orca-ide_${version}_amd64.deb`,
  HUB_ARM64: `orca-ide_${version}_arm64.deb`
};
const found = {};
for (const [key, filename] of Object.entries(want)) {
  const asset = (release.assets || []).find((a) => a.name === filename);
  if (!asset) throw new Error(`Missing release asset: ${filename}`);
  const dm = /^sha256:([a-f0-9]{64})$/.exec(asset.digest || '');
  if (!dm) throw new Error(`Missing SHA256 digest for ${filename}`);
  found[key] = { url: asset.browser_download_url, sha: dm[1] };
}
const existing = fs.readFileSync(lockFile, 'utf8');
const keepLines = existing.split('\n').filter((line) =>
  /^(HUB_BASE_IMAGE=|# Official multi-architecture|TAILSCALE_VERSION=|TAILSCALE_IMAGE=)/.test(line)
);
const next = [
  '# Shared by Bash and PowerShell ConvertFrom-StringData. Keep values unquoted.',
  `# Source: https://api.github.com/repos/stablyai/orca/releases/tags/${tag}`,
  `ORCA_VERSION=${version}`,
  `LINUX_X64_URL=${found.LINUX_X64.url}`,
  `LINUX_X64_SHA256=${found.LINUX_X64.sha}`,
  `LINUX_ARM64_URL=${found.LINUX_ARM64.url}`,
  `LINUX_ARM64_SHA256=${found.LINUX_ARM64.sha}`,
  `WINDOWS_X64_URL=${found.WINDOWS_X64.url}`,
  `WINDOWS_X64_SHA256=${found.WINDOWS_X64.sha}`,
  '# The hub needs the full Electron serve runtime, including mobile desktop relay.',
  `HUB_X64_URL=${found.HUB_X64.url}`,
  `HUB_X64_SHA256=${found.HUB_X64.sha}`,
  `HUB_ARM64_URL=${found.HUB_ARM64.url}`,
  `HUB_ARM64_SHA256=${found.HUB_ARM64.sha}`,
  ...keepLines,
  ''
].join('\n');
fs.writeFileSync(`${lockFile}.tmp`, next, 'utf8');
fs.renameSync(`${lockFile}.tmp`, lockFile);
console.log(`Updated versions.lock.env to Orca ${version}`);
NODE
