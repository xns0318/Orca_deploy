# Orca deployment scripts

Install Orca in existing Linux containers. Install the Windows desktop app and
pair it with each container. A single optional Tailscale gateway container can
provide private access to every agent container on its Docker networks.

`install.sh` only installs Orca inside the existing agent container. It does not
create agent containers, change entrypoints, publish ports, or install/login
agent CLIs. `gateway/install.sh` creates only the shared gateway. Tailscale stays
out of the Linux host and agent containers.

## Release and requirements

- Pinned release: [Orca v1.4.259](https://github.com/stablyai/orca/releases/tag/v1.4.259).
  Official artifact URLs and SHA256 values are in `versions.lock.env`.
- Linux: x86_64 or aarch64, glibc >= 2.28, Bash, curl, CA certificates, tar,
  coreutils, util-linux (`flock`), `hostname`, and `/proc`. Debian 10+/Ubuntu 20.04+ qualify.
  Alpine/musl is unsupported. The server package includes Node; Electron,
  Xvfb, systemd, and a global Node installation are not required.
- Windows: 64-bit Windows, PowerShell 5.1 or 7, outbound HTTPS, and trust in the
  official installer's signing certificate. Use the same Windows account as
  the desktop app. Git is needed for cloning; downloading a repository ZIP also works.
- Both machines need access to GitHub release downloads. Windows must reach
  the container's advertised WebSocket endpoint. For the shared-gateway setup,
  first install and sign into Tailscale on Windows, then approve the gateway routes.
- Run Linux installation as the user who owns the projects and agent logins,
  with that user's HOME and PATH. Do not add `sudo` just for this installer.
- Keep the install prefix on persistent storage. Use a separate prefix/profile
  for each container. Do not put an initialized Orca profile in a reusable image.

## Clone

GitHub: [xns0318/Orca_deploy](https://github.com/xns0318/Orca_deploy)

```sh
git clone https://github.com/xns0318/Orca_deploy.git orca-deploy
cd orca-deploy
```

GitLab: [ai/orca_deploy](http://gitlab.csmar.com/ai/orca_deploy).
Use SSH with a key that has repository read access:

```sh
git clone git@gitlab.csmar.com:ai/orca_deploy.git orca-deploy
cd orca-deploy
```

Choose one repository. Both use the same deployment files; the commands below
are identical after cloning.

For a repeatable rollout, check out the same reviewed deployment-repository
commit on each machine. The release lock prevents automatic selection of `latest`.
Review scripts before execution. Never commit pairing files or Orca state.

## 0. Shared network gateway (once per server)

On the Linux Docker host, create one gateway on the existing agent network:

```sh
bash gateway/install.sh --network bridge
```

It prompts privately for a Tailscale auth key. It does not install Tailscale on
the host. Multiple existing networks can share one gateway by repeating
`--network`. Set up access policy and approve the advertised routes before use.
See the [gateway deployment guide](gateway/README.md) for credentials, policy,
route approval, persistence and the Windows connectivity check.

Skip this step when an existing private network already connects Windows to Orca.

## 1. Existing Linux container

After the shared gateway's subnet route and access policy are ready:

```sh
bash install.sh --name dev-01 --address auto
```

`auto` selects the container's single private IPv4 address, such as
`ws://172.17.0.17:6768`. It does not verify gateway reachability. For multiple
private addresses, specify the one on an advertised Docker network explicitly.

This downloads and verifies the server package, creates an isolated profile,
starts the official supervised server, checks authenticated local RPC, sets the
host name, and writes a private pairing file. It leaves existing Orca checkouts
and profiles untouched.

Default installation: `$HOME/.local/share/orca-deploy` (or
`$XDG_DATA_HOME/orca-deploy` when XDG_DATA_HOME is set).

The installation prints the absolute paths for:

- `bin/orca-service`: start, stop, restart, status, logs, pair, and CLI access.
- `server.pairing.json`: private one-time pairing offer; file mode `0600`.

The server listens on `0.0.0.0:6768` inside its network namespace. With the
gateway, use each container's private IP and port `6768`; no host port mapping
is required. Containers in separate network namespaces can all use `6768`.
Containers sharing a network namespace require distinct `--port` values.

If you already use a different private entry point, an explicit address remains
supported. For example, a reachable host address `100.64.0.10:16768` mapped to
this container's `6768` would use:

```sh
bash install.sh --name dev-01 --address ws://100.64.0.10:16768
```

These IP addresses are examples; use the actual route and address for each container.

Expose endpoints only through your private network and restrict access with
your existing firewall/Tailscale policy. `--refuse-public` rejects public source
addresses at Orca; private-address NAT is not a substitute for a firewall.

Additional options:

```sh
bash install.sh --name dev-01 --address auto \
  --port 6768 --prefix /persistent/dev-01/orca
bash install.sh --address auto --no-start
```

Repeated installation reuses the release, identity and profile. A healthy running
server stays running. Stop it explicitly before changing its configuration or version.

### Container restarts

Background startup survives shell logout. A stopped/recreated container needs
startup integration in your own container configuration. This repository leaves
that configuration unchanged.

Call this from your existing container startup mechanism:

```sh
$HOME/.local/share/orca-deploy/bin/orca-service start
```

For an existing process supervisor, use the foreground command instead:

```sh
$HOME/.local/share/orca-deploy/bin/orca-service run
```

Use the actual prefix printed by the installer. Run under the original user,
HOME and agent PATH. Do not launch another Orca process against the same profile.

## 2. New Windows computer

Transfer `server.pairing.json` privately to this Windows account, for example
through an existing SSH/SFTP connection. Do not paste it into Git or chat logs.
If you can SSH into the container, a PowerShell example is:

```powershell
scp user@container:/home/user/.local/share/orca-deploy/server.pairing.json "$HOME\Downloads\dev-01.pairing.json"
```

From the cloned repository in a normal PowerShell window:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\Setup.ps1 -Name dev-01 -PairingFile "$HOME\Downloads\dev-01.pairing.json"
```

This verifies SHA256 and Authenticode, runs the official per-user installer,
checks the installed version, pairs via Orca's official CLI, checks remote RPC,
then opens the desktop app. It writes no hand-built Orca configuration files.
The execution-policy setting applies only to this process.

Default app path: `%LOCALAPPDATA%\Programs\Orca`.
Pairings use the app's shared profile: `%APPDATA%\orca`.
For an existing custom app path, pass `-InstallDirectory 'C:\path\to\Orca'`.
Use `-NoLaunch` to skip opening the app, or omit `-Name` to install only.

After successful pairing, delete the transferred offer:

```powershell
Remove-Item "$HOME\Downloads\dev-01.pairing.json"
```

### Add another container

Generate that container's offer with `orca-service pair`, transfer it privately,
then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\Connect.ps1 -Name dev-02 -PairingFile "$HOME\Downloads\dev-02.pairing.json"
```

Each new client needs its own offer. Run `orca-service pair` again after an
earlier offer is consumed. Existing paired computers keep their credentials.
For a phone, `orca-service pair --mobile` produces the native mobile pairing offer.

### Repeat execution

For an existing name, omit `-PairingFile`. The script verifies the saved connection:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\Connect.ps1 -Name dev-01
```

Supplying a new pairing file for an existing name stops with an explicit error.
Repair or remove that connection in Orca Settings before pairing it again.
A failed status check retains the saved record and returns an error.

If an installed Windows app has a different version, Setup preserves it and
stops. Use Connect for pairing only. Planned upgrades should be explicit; do not
downgrade a profile that has already been migrated by a newer Orca release.
The lock pins deployment downloads; the desktop app's own updater is separate.

## Operations and scope

```sh
$HOME/.local/share/orca-deploy/bin/orca-service status
$HOME/.local/share/orca-deploy/bin/orca-service logs
$HOME/.local/share/orca-deploy/bin/orca-service pair
$HOME/.local/share/orca-deploy/bin/orca-service stop
```

`stop` sends SIGTERM only to a process matched by PID, process start time and
installation marker. It retains the profile. Stopping/restarting can affect
active sessions; schedule operational changes accordingly. The official
supervisor retries crashes and stops after its crash threshold. Inspect the log
when health checks fail.

The server controls this container's projects and agent processes under the
installation user. Agent binaries, model credentials and provider login remain
your responsibility. Start managed sessions through Orca. Existing independent
terminal sessions are not automatically adopted.

This server-only package supports remote CLI/session workflows. Electron-only
browser panes and dictation are outside its scope. Network reachability alone
does not pair a client: the private offer exchange is required.

Back up the whole persistent prefix while stopped, especially `state/` and
`config.env`. Keep the same user and HOME when restoring. Do not restore the same
identity into multiple simultaneously running containers.

## Tests

These tests use temporary fixture archives, simulated RPC/Docker responses, and
mocked Windows pairing responses. They never launch a real gateway, Orca server
or Windows installer.

```sh
bash tests/linux.sh
bash tests/gateway.sh
pwsh -NoProfile -File tests/windows.ps1
```

Linux test dependencies: Node >= 18, ripgrep and the installation prerequisites.
PowerShell tests run on Windows or Linux, without extra test modules.

Real Windows acceptance still requires: fresh per-user install, signature check,
pairing with a live container, appearance in the desktop UI, and repeat setup.
Real network acceptance requires testing the advertised endpoint from Windows.
Real gateway acceptance additionally requires a Docker daemon and Tailscale
account; mocked Docker tests do not exercise container networking or enrollment.
The scripts report RPC success only after an actual status check when deployed.
