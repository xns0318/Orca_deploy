# Persistent Mobile Hub

The phone pairs once with a server-side Orca hub. The hub knows all registered
agent containers. Windows can be offline. Agents and project files remain in
their original containers.

```text
Orca Mobile + Tailscale
        |
        | ws://<gateway-tailscale-ip>:6768
        v
orca-gateway: Tailscale Serve TCP + existing subnet routes
        |
        | shared Docker network namespace
        v
orca-hub: full Linux Orca, Electron serve, virtual display, status observer
        |
        +-- container A: Orca server + agent CLIs
        +-- container B: Orca server + agent CLIs
        +-- container C: Orca server + agent CLIs
```

Two infrastructure containers are managed by the same repository. Agent containers
are created separately. Neither the host nor agent containers need Tailscale.
No Docker socket, host display, host network or published host port is mounted into
the hub. There is no public enrollment API. Enrollment runs through the operator's
existing Docker access on the host.

## Install On The Docker Host

Requirements: a local Linux Docker daemon with image-build support, Bash, Git,
coreutils, util-linux, outbound HTTPS to GitHub, Debian mirrors and image registries.
Allow approximately 2 GB of spare disk for the first image build. The full app
download is about 195 MiB on amd64. The host needs no systemd, desktop, Node or Compose.
Agent containers retain the prerequisites in the root README.

From the cloned repository:

```sh
git pull --ff-only
bash hub/install.sh --network bridge --dry-run
bash hub/install.sh --network bridge
```

The existing `orca-gateway` is retained. On first deployment only, the gateway
installer requests a Tailscale auth key using hidden input. For automation:

```sh
bash hub/install.sh --network bridge --auth-key-file /secure/gateway.authkey
```

For a gateway originally installed on several networks, repeat the same ordered
`--network` options. The installer checks the existing topology and keeps its identity.
The hub shares all of that gateway's networks. No agent-container network is modified.

The installer prints the real central address, such as `ws://100.92.0.8:6768`.
The `100.*` address comes from the gateway. It stays independent of agent-container IPs.
Allow your phone's identity/device to reach this gateway TCP port in Tailscale policy.
The installer enables only a private `tailscale serve --bg --tcp=6768` forwarder.
It does not enable Funnel or overwrite an unrelated listener. Existing subnet
routes stay available for direct Windows-to-container connections.

## Offline Hub Image

If installation stops at `FROM` with a `registry-1.docker.io` timeout, the Docker
daemon cannot reach Docker Hub. The gateway remains running. Import a complete
hub image built on a connected machine; the target host then needs no Docker Hub,
Debian mirror or Orca package download for the hub.

On an internet-connected Linux Docker builder with the same target architecture
and repository revision:

```sh
bash hub/export-image.sh --output /tmp/orca-hub.tar.gz
```

Copy both `orca-hub.tar.gz` and `orca-hub.tar.gz.sha256` to the target host.
Keep the bundle outside the Git repository. From the matching checkout, run:

```sh
bash hub/install.sh --network bridge --image-archive ../orca-hub.tar.gz
```

The installer checks SHA256 before modifying Docker state, uses
[`docker image load`](https://docs.docker.com/reference/cli/docker/image/load/),
and checks the image tag, Linux architecture and source fingerprint before starting
the hub. An explicit `--image-sha256 DIGEST` can replace the adjacent checksum file.
Only import bundles from your own trusted builder. The checksum detects corruption;
it does not authenticate a separately obtained publisher. Export fails if its output
already exists. For a builder configured without a bridge, use `--build-network host`.
Builds pass through the standard `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` and lowercase
environment variables using Docker's predefined proxy arguments, without adding
them to the final image environment.

The archive contains only the image, not Tailscale keys, hub volumes, phone pairings
or agent sessions. Keep the same repository revision for future deployments of that
archive. A fresh gateway still needs its own Tailscale image and enrollment; an
existing healthy gateway and its state are preserved. Re-running installation with
the same archive does not rebuild or recreate the hub.
Allow at least 3 GB of free disk for the archive and import; Docker storage drivers
can require additional space.

## Enroll An Existing Container

Run on the Docker host, from the same repository:

```sh
bash hub/connect.sh --container 4299bfe79667 --name 2-machine-dev
```

For each subsequent container, use its name or ID and a unique Orca label:

```sh
bash hub/connect.sh --container my-next-container --name dev-02
```

This command transfers only the installer files into a temporary directory in
the target container, installs/starts Orca under the selected user, and securely
passes a fresh access offer through Docker stdin to the hub. Credentials are not
placed in command arguments, repository files, host temporary files or logs.

For an existing installation, its name, profile, identity and advertised address
are preserved. The hub selects the target's private address on a shared network.
Repeated successful enrollment keeps the saved grant. A changed address with the
same server key is updated in place. A different server key under an existing name
is refused; review and explicitly remove the old registration first.

For a non-root agent user, nonstandard prefix or several shared networks:

```sh
bash hub/connect.sh --container my-next-container --name dev-02 \
  --user developer --prefix /home/developer/.local/share/orca-deploy --network agents
```

The user must already exist in the container with a valid HOME. Use the user and
prefix that own the current Orca installation and agent credentials. Existing
installations retain their listen port; `--port` selects the first-install port.

The script does not install agent CLIs or model credentials, recreate the agent
container, modify its entrypoint, or adopt independent terminal sessions. For
container restart startup hooks, see the root README. Rerunning `connect.sh`
also starts a stopped Orca service and refreshes a changed container IP.

## Pair The Phone Once

1. Sign the phone into the same Tailscale network.
2. On the host, run:

```sh
docker exec -it orca-hub hubctl pair
```

3. Open Orca Mobile and scan this central QR code. Keep the offer private.
4. Open a registered container's workspace and session.

New containers appear under this central connection after registration and status
refresh, normally within a few seconds. No per-container phone scan is needed.
When moving from the old Windows pairing, pair with the hub once, then remove the
old phone connection after verifying the hub. Existing Windows grants stay intact.

The central pairing authorizes access to the hub's registered servers. Register
only containers intended for that same user's phone. Each phone has its own
revocable Orca grant. Reinstallation with intact state preserves these grants;
clearing the phone's app data, revocation or loss of hub state requires pairing again.

## Why The Full Runtime

The pinned `1.4.259` standalone `orcad` package does not install the desktop's
mobile multi-server provider. The hub uses the official full Linux package with
`ORCA_SERVE_RUNTIME=electron`, launched under Xvfb with no visible desktop.
This also works on a server with no physical display.
The runtime selection flag is documented in [Orca's server guide](https://orca.dev/docs/remote-servers#alternative-orca-serve).

This release's windowless mode has no renderer polling remote-server status.
A small local observer uses the release's own encrypted mobile transport to
refresh `status.get` through the hub for each saved server. It has a separate
private, mobile-scoped credential in the hub volume. It performs no agent work
and produces no QR prompt. The health check verifies both the runtime and this
observer. Remote servers being offline do not make the entire hub unhealthy.

Pairing, encryption, device delegation and atomic server-registry writes all use
the pinned official package's modules. No Orca source fork or hand-written crypto
is included. Version updates must pass the live test before updating the lock.

## Persistence And Operations

```sh
docker exec orca-hub hubctl status
docker exec orca-hub hubctl list
docker logs --tail 100 orca-hub
docker restart orca-hub
```

Persistent volumes:

| Volume | Contents |
| --- | --- |
| `orca-gateway-state` | Tailscale identity and private TCP Serve settings |
| `orca-hub-home` | Orca identity, phone grants, remote-server registry and observer credential |

Retain both volumes across restarts and recreations. Back up the hub home while
the hub is stopped; treat backups as credentials. Never run two hubs against the
same home volume or restore one identity into several active instances.

The app runs as UID/GID `10001`, with a read-only root filesystem, no Linux
capabilities and no privilege escalation. Chromium's inner sandbox is disabled
within this dedicated container; Docker provides the outer isolation. Do not
mount host projects, Docker sockets or agent credentials into the hub. Headless
keyring storage is protected by file permissions and the private volume, not a
desktop keychain. Encrypt sensitive volume backups separately.

The application artifact and base-image digest are pinned. Debian dependency
packages are resolved from its package repositories during build, so this is
a repeatable deployment, not a bit-identical offline image build. Retain the built
image in your own registry for air-gapped or byte-identical rollouts.

To remove a hub registration (does not delete the container or its sessions):

```sh
docker exec orca-hub hubctl remove dev-02
```

Use Orca's server access controls to revoke the former hub grant on that node
when retiring access. Removing a registry entry alone is not credential revocation.

An image/configuration change requires an explicit hub replacement:

```sh
bash hub/install.sh --network bridge --recreate
```

This stops/replaces only the owned hub container and keeps its home volume. Agents
continue on their nodes; phones reconnect after the hub starts. If the gateway
itself was recreated, rerun this command so the hub joins its new network namespace.
Keep the same central address and port. After a whole-host restart, inspect both
containers; rerun `hub/install.sh` if Docker starts the dependent namespace out of order.

## Verification

Fixture tests (no Docker daemon needed):

```sh
bash tests/linux.sh
bash tests/gateway.sh
bash tests/hub.sh
node --test tests/hub-config.cjs
```

After building or loading a matching image, run the container smoke test:

```sh
bash tests/hub-container.sh
```

This creates disposable, isolated containers and a volume. It checks real image
startup, the observer, non-root read-only operation, mobile pairing generation and
identity persistence across restart, then removes its test resources. It needs
no Tailscale enrollment and does not touch the deployment containers.

Real protocol test with unpacked, checksum-verified release artifacts:

```sh
node tests/hub-live.cjs /path/to/full-app/opt/Orca /path/to/orca-server
```

It starts disposable profiles and ports, runs the hub and three real standalone
servers, pairs a mobile-scoped encrypted client once, reads files and operates
remote terminals, adds the third server without re-pairing, then restarts the hub
and uses the same credential again. It uses the released package's transport
modules; no upstream source checkout or AI provider login is required. Temporary
diagnostic files remain private under `/tmp/orca-hub-live-*`. Its cleanup targets
only processes bearing that test's unique environment marker.

Deployment acceptance on your server:

1. `hub/install.sh` reports runtime and observer ready, with a private TCP forwarder.
2. Enroll two containers and verify their projects appear on the phone.
3. Shut down Windows. Read output and send input in both remote sessions.
4. Enroll a third container. Open it on the already-paired phone without scanning.
5. Restart the hub. Confirm the same phone pairing and remote sessions work.

The live protocol test covers application behavior. Docker image execution,
Tailscale policy and the real phone UI also need this host-side acceptance.
Linux amd64 protocol checks were run with both root and unprivileged test users.
The gateway forwarding uses [Tailscale Serve TCP](https://tailscale.com/docs/reference/tailscale-cli/serve#use-a-tcp-forwarder)
with persistent `--bg` configuration.
