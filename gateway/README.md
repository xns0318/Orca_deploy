# Shared Tailscale gateway

One gateway container connects Windows to the existing agent containers. Only
the gateway and Windows run Tailscale. The Linux host and agent containers do
not need a Tailscale installation.

```text
Windows: Orca + Tailscale
          |
Tailscale gateway container
          |
Existing Docker bridge network(s)
          |
Agent containers: Orca on TCP 6768
```

The gateway uses Tailscale's supported [userspace subnet routing](https://tailscale.com/docs/reference/kernel-vs-userspace-routers).
It forwards TCP/UDP connections, including Orca WebSocket traffic. It requires
no TUN device, host networking, host IP-forwarding change, privileged mode, added
Linux capabilities, published ports, or Docker socket mount inside the gateway.
The script only uses Docker on the host to create and manage this gateway.

## 1. Prepare once

- Run on the Linux Docker host, with Docker CLI access to the local daemon,
  Bash, coreutils and util-linux (`flock`). Docker Compose, Node and a host
  Tailscale package are not required.
- Agent containers must be reachable from the chosen existing Docker bridge
  networks. Inter-container communication must be enabled. The first network
  needs outbound access to GHCR/Tailscale and normal internet connectivity.
- Use a Tailscale account with permission to enroll the gateway and approve
  subnet routes. Windows must use the same tailnet.
- Create a **non-ephemeral auth key** in the [Tailscale admin console](https://login.tailscale.com/admin/settings/keys).
  A single-use key works with persistent state. Enable pre-approval when your
  tailnet requires device approval. Keep the key out of Git and chat messages.
- Check for overlapping networks on Windows, other VPNs, and other subnet
  routers before approving routes. Use a non-overlapping agent subnet when
  planning containers. Advertised routes must have an unambiguous destination.

## 2. Create the shared gateway

From the repository checkout on the Docker host:

```sh
bash gateway/install.sh --network bridge --dry-run
bash gateway/install.sh --network bridge
```

The first command only reads Docker metadata. The second prompts for the auth
key with hidden input, then creates `orca-gateway`. For unattended provisioning,
provide an existing private file instead:

```sh
bash gateway/install.sh --network bridge --auth-key-file /secure/orca-gateway.authkey
```

The key file must be outside this repository, owned by the current user, and
readable only by that user (mode `600` or `400`). The interactive prompt stores
it under `$XDG_DATA_HOME/orca-gateway/orca-gateway/`, or
`$HOME/.local/share/orca-gateway/orca-gateway/` by default.

The script pins the official image by version and multi-architecture digest,
reads each network's actual IPv4 subnet from Docker, and copies the auth key
into its private state volume with container-root ownership and private file
permissions. Credentials are not placed in container environment values or command
arguments. The gateway's device identity and bootstrap key are kept in the
`orca-gateway-state` named volume. Preserve this volume across restarts and
protect its backups as credentials. The host's original key file is not bind-mounted.
Tailscale uses saved device state after enrollment; an expired bootstrap auth
key does not replace that state. Configure device key expiry appropriately for
an unattended gateway in the Tailscale admin console.

Several existing networks can share the same gateway:

```sh
bash gateway/install.sh --network bridge --network other-agent-network
```

New agent containers on these networks need no additional gateway installation.
The gateway advertises their existing IPv4 subnets. IPv6 routes, overlay networks,
and macvlan/ipvlan networks are outside this script's scope.

## 3. Restrict access, then approve routes

**A subnet route covers the entire subnet, not just Orca.** Before enabling it,
configure tailnet access for your Windows user/device and the Orca TCP ports.
Existing broad allow rules must be narrowed by your tailnet administrator;
adding a restrictive grant alongside an existing allow-all rule does not restrict
that rule. Preserve access policies for other services when making this change.

For example, this is a grant to merge into your reviewed policy, replacing the
example identity and subnet with the values used in your environment:

```json
{
  "grants": [
    {
      "src": ["operator@example.com"],
      "dst": ["172.17.0.0/16"],
      "ip": ["tcp:6768"]
    }
  ]
}
```

In the [Machines page](https://login.tailscale.com/admin/machines), find the
gateway, open **Edit route settings**, and approve the routes printed by the
installer. Approve the device too when required by your tailnet policy.
These approvals are administrator actions; the script does not change your
tailnet policy or approve routes automatically.

Windows automatically accepts approved subnet routes. Install and sign into
the [Windows Tailscale client](https://tailscale.com/download/windows) once.
The repository's Windows `Setup.ps1` installs Orca; it leaves Tailscale and its
account login to you.

## 4. Install Orca in each agent container

In the agent container's own repository checkout:

```sh
bash install.sh --name dev-01 --address auto
```

`auto` selects the container's single private IPv4 address. A container with
several private addresses needs an explicit address on an advertised network:

```sh
bash install.sh --name dev-01 --address ws://172.17.0.17:6768
```

With the shared gateway, this is the container IP and container listen port.
No host port publishing is needed. The gateway has no agent credentials or
session storage; Orca in each agent container owns its sessions and pairing.

From Windows, after Orca is running, test the real destination:

```powershell
Test-NetConnection 172.17.0.17 -Port 6768
```

Expect `TcpTestSucceeded: True`, then follow the main README to transfer the
private pairing offer and run `windows/Setup.ps1` or `windows/Connect.ps1`.
Use a TCP test for this userspace gateway, not ping as the acceptance criterion.
A container recreation may change its Docker IP. Use stable addresses in your
container configuration, or update the Orca advertised address and client pairing
when that address changes.

## Operations

```sh
docker logs --tail 100 orca-gateway
docker exec orca-gateway tailscale status
docker stop orca-gateway
docker start orca-gateway
```

The gateway uses `unless-stopped` restart behavior and bounded Docker logs.
Repeated installation with the same options preserves the gateway and its state.
An unrelated container or volume with the same name is refused. The installer
checks local gateway health, not route approval or Windows-to-Orca connectivity.

Changes to the pinned image or network list require a controlled recreation.
This interrupts remote connections. In a maintenance window, stop and remove
only the gateway container, keep its named volume and auth-key file, then rerun
the installer with the desired complete network list and original auth-key file
(keep a private copy for recreation):

```sh
docker stop orca-gateway
docker rm orca-gateway
bash gateway/install.sh --network bridge --network other-agent-network \
  --auth-key-file /secure/orca-gateway.authkey
```

Review access policy and approve any new routes. Do not remove the state volume
unless you intend to enroll a new Tailscale device. The script never removes or
restarts agent containers and never changes their network attachments.

## References

- [Official Docker configuration](https://tailscale.com/docs/features/containers/docker/docker-params)
- [Subnet routing and route approval](https://tailscale.com/docs/features/subnet-routers)
- [Userspace subnet routing](https://tailscale.com/docs/reference/kernel-vs-userspace-routers)
- [Docker bridge connectivity](https://docs.docker.com/engine/network/drivers/bridge/)
