# Tailscale on minlin

This app runs the host's `tailscaled` as the only program in a minlin microVM,
joining it to your tailnet with kernel-mode networking: a real `tailscale0`
TUN device and policy routing, not userspace networking. It can also serve as
an exit node.

## Requirements

On the host:

- Tailscale installed (`tailscaled` and `tailscale`). Only `tailscaled` is
  copied into the VM; its version is whatever the host has.
- `strip` (binutils), plus what minlin itself needs (see the top-level
  README).
- An auth key from the admin console (Settings → Keys). Use an **ephemeral**
  key: every disk rebuild registers a new node, and ephemeral nodes are
  removed automatically once they go offline. Make it reusable if you'll
  rebuild with the same key.

## Build and boot

    ./build-linux.sh                     # once, or after kernel/init changes
    TS_AUTHKEY=tskey-auth-... ./build-disk.sh tailscale
    GUEST_NAME=minlin-ts MEM=48 HOSTFWD=8080 ./boot-qemu.sh

- `HOSTFWD` switches QEMU to user-mode networking, which gives the guest
  outbound internet access through the host. Without it the NIC is a socket
  netdev that can't reach Tailscale's servers. (The port it forwards to the
  guest's port 80 isn't used by this app.)
- `GUEST_NAME` becomes the hostname, which is the node's name in the tailnet.
  It defaults to `minlin`; machines with the same name get `-1`, `-2`
  suffixes.
- `MEM` is the guest RAM in MB. See [Memory](#memory).

Under Firecracker, the guest's bridge (`br0` by default) must have a route to
the internet, e.g. NAT on the host:

    GUEST_NAME=minlin-ts MEM=48 ./boot-firecracker.sh

The node shows up in the admin console a few seconds after boot. tailscaled's
log goes to the serial console. Stopping the VM takes the node offline; an
ephemeral node is then removed.

## Exit node

    TS_AUTHKEY=tskey-auth-... TS_EXIT_NODE=1 ./build-disk.sh tailscale

Then boot as above and approve the node as an exit node in the admin console
(machine → Edit route settings → Use as exit node), unless an
`autoApprovers` rule in your policy file does it for you. To test, pick the
node as the exit node on a client and check that `curl ifconfig.me` shows the
host's public IP.

With `TS_EXIT_NODE=1`:

- the disk gets an `/etc/sysctl.conf` with `net.ipv4.ip_forward = 1`, which
  init applies at boot;
- tailscaled advertises `0.0.0.0/0` and `::/0` and runs with netfilter on, so
  it masquerades forwarded traffic using nftables (the kernel has nftables
  NAT built in; no `nft` or `iptables` tools are needed).

Exit traffic is **IPv4 only**: the minlin kernel has no IPv6.

## Memory

The default 32MB boots, but tailscaled is a ~30MB Go binary and the guest
thrashes paging it in: startup takes seconds and TLS handshakes time out.
Startup time for tailscaled's backend:

| Guest RAM | Startup |
|-----------|---------|
| 32MB      | ~9s, with TLS timeouts |
| 40MB      | ~1.6s |
| 48MB      | ~25ms |
| 64MB      | ~25ms |

Use at least 48MB, and 64MB for headroom: memory use grows once the node is
logged in, and with exit traffic.

## What's on the disk

| Path | Purpose |
|------|---------|
| `/usr/sbin/tailscaled` | the host's tailscaled, stripped of debug info |
| `/etc/tailscaled.conf` | tailscaled's config file (written by `install.sh`) |
| `/etc/init.conf` | starts tailscaled, restarting it if it exits |
| `/etc/resolv.conf` | DNS via 1.1.1.1 and 8.8.8.8 |
| `/etc/ssl/certs/ca-certificates.crt` | CA roots for TLS to Tailscale's servers |
| `/etc/sysctl.conf` | IPv4 forwarding (exit node only) |
| `/var/lib/tailscale/` | tailscaled's state (node key, profile) |

There is no `tailscale` CLI: it's a second ~24MB Go binary, and the guest
has no shell to run it from anyway. Everything `tailscale up` would set comes
from `--config=/etc/tailscaled.conf` instead. That file locks tailscaled's
settings, so to change them, edit `install.sh` and rebuild the disk.

The auth key is stored in plain text in `/etc/tailscaled.conf`, so it's in
`linux-src/rootfs/` and `sys/diskimage` on the host (both ignored by
git). Treat those files like the key, or use a short-lived ephemeral key.

## Updating Tailscale

The VM never updates itself; auto-update is turned off in the config so the
tailnet-wide auto-update default doesn't try. Upgrade Tailscale on the host
and run `build-disk.sh` again.

## Kernel support

`build-linux.sh` builds these into the (app-independent) kernel for
Tailscale:

| Option | Why |
|--------|-----|
| `EVENTFD` | the Go runtime's network poller won't start without it |
| `UNIX` | tailscaled's local API socket |
| `TUN` | the `tailscale0` interface |
| `IP_ADVANCED_ROUTER`, `IP_MULTIPLE_TABLES` | Tailscale's policy routing rules |
| `PROC_SYSCTL` | `/proc/sys`, for `net.ipv4.ip_forward` |
| `NETFILTER`, `NF_CONNTRACK`, `NF_NAT`, `NF_TABLES`, `NF_TABLES_IPV4`, `NFT_CT`, `NFT_NAT`, `NFT_MASQ` | nftables NAT for exit traffic |

It also patches the kernel's default overcommit policy to "always". Go
reserves 32MB of address space at startup, which the default heuristic refuses
outright on a 32MB guest with no swap. Altogether these cost about 160KB of
free RAM at boot.

## Log messages you can ignore

- `TPM: error opening: stat /dev/tpmrm0` and
  `linuxfw: clear iptables: exec: "iptables": executable file not found`:
  there's no TPM, and no iptables, so tailscaled falls back to nftables.
- `router: disabling tunneled IPv6 due to system IPv6 config` and
  `magicsock: unable to bind udp6`: the kernel has no IPv6.
- `dns: inotify: NewDirWatcher: function not implemented`: kernels built
  before `INOTIFY_USER` was added (for Pi-hole) have no inotify; tailscaled
  doesn't need to watch `/etc/resolv.conf` here. Untested with the current
  kernel, where the message should be gone.
- `health(warnable=ip-forwarding-off): ... IP forwarding is disabled` (exit
  node only): IPv4 forwarding is on; this is about IPv6 forwarding, checked
  because `::/0` is advertised. An exit node has to advertise both routes.
- `Drop: TCP{...} destination not allowed`: Tailscale's packet filter
  dropping traffic addressed to a tailnet IP that isn't this node, usually a
  client's old connection to a previous instance of the VM reaching it
  through the exit node.
