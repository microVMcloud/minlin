# Xray on minlin

This app runs [Xray-core](https://github.com/XTLS/Xray-core) as the only
program in a minlin microVM. It's a VLESS server using the REALITY transport,
listening on guest port 80. Connections that don't have the REALITY key are
passed on to a real TLS site (`www.microsoft.com` by default), so the port
looks like that site to a scanner.

## Requirements

On the host:

- `curl`, `unzip`, `openssl` and `sha256sum`, plus what minlin itself needs
  (see the top-level README).
- Internet access at build time. The build downloads the official
  `Xray-linux-64.zip` release and checks it against the release's `.dgst`
  file. Nothing is taken from the host's packages.

The build host doesn't have to be able to run the x86-64 binary: the REALITY
keys are made with `openssl`. When the host is x86-64 Linux, the build also
runs `xray run -test` on the generated config.

## Build and boot

    ./build-linux.sh                     # once, or after kernel/init changes
    ./build-disk.sh xray
    MEM=64 HOSTFWD=8080 ./boot-qemu.sh

The build prints a `vless://` link to import into a client (v2rayN, Nekoray,
Shadowrocket and so on). `XRAY_HOST` and `XRAY_PORT` only set the address in
that link, and default to `localhost:8080` to match `HOSTFWD=8080`. For a
server other machines connect to:

    XRAY_HOST=vpn.example.com XRAY_PORT=8443 ./build-disk.sh xray
    MEM=64 HOSTFWD=8443 BIND_ADDR=0.0.0.0 ./boot-qemu.sh

`HOSTFWD` forwards a host port to guest port 80 and gives the guest the
outbound internet access it needs, both for its clients' traffic and for
reaching the `XRAY_SNI` site. To make the port reachable from other machines,
add `BIND_ADDR=0.0.0.0`. REALITY needs nothing else to be safe on the open
internet. Under Firecracker the guest has its own address, so clients
connect to port 80 on it.

| Variable | Meaning |
|----------|---------|
| `XRAY_VERSION` | release tag, such as `v26.11.9`. Default: the latest release, looked up at each build |
| `XRAY_SNI` | the site REALITY impersonates. It must support TLS 1.3 and HTTP/2, and be reachable from the guest. Default `www.microsoft.com` |
| `XRAY_HOST`, `XRAY_PORT` | the address in the printed link |

Each release is cached in `linux-src/xray/<version>/`, so a rebuild only
downloads a new release.

### Keys

The client UUID, REALITY key pair and short ID are generated on the first
build and kept in `linux-src/xray_reality.env` (mode 0600). Rebuilding keeps
them, so clients keep working. To replace them, delete the file and rebuild,
then give clients the new link.

The file has the same format as the `/opt/xray/reality.env` written when
setting Xray up by hand in the `bash` app. To keep a VM's existing keys,
copy that file to `linux-src/xray_reality.env` before building.

To check the disguise from outside:

    openssl s_client -connect <host>:<port> -servername www.microsoft.com \
        </dev/null 2>/dev/null | grep -E 'subject=|issuer='

It should show the `XRAY_SNI` site's certificate.

## Memory

Not measured yet. The binary is a ~35MB static Go program (v26.11.9). By
comparison, tailscaled's ~30MB binary needs 48MB to page in without
thrashing (see `apps/tailscale`). Start at `MEM=64`. When the server has been
set up by hand, it has run at `MEM=128` alongside bash.

## What's on the disk

| Path | Why |
|------|-----|
| `/usr/local/bin/xray` | the release binary, static, no libraries needed |
| `/etc/xray/config.json` | generated config, mode 0600 as it holds the private key |
| `/etc/resolv.conf` | DNS via 1.1.1.1 and 8.8.8.8, for clients' destinations and the `XRAY_SNI` site |
| `/etc/init.conf` | `respawn` of `xray run -c /etc/xray/config.json` |

`geoip.dat` and `geosite.dat` aren't installed. They add ~20MB to the disk
and memory use when loaded, and the config doesn't use `geoip:` or
`geosite:` rules. If you add such rules, unzip them next to the binary.

## Config notes

- **Private addresses are blocked.** Clients can't reach `127.0.0.0/8`,
  RFC 1918 ranges, link-local addresses (including the cloud metadata
  service at `169.254.169.254`) or CGNAT addresses through the proxy. Under
  QEMU this matters: `10.0.2.2` is the host's own loopback. The routing
  rule uses `IPOnDemand`, so a domain name that resolves to one of these is
  blocked too.
- **IPv4 only.** The kernel has no IPv6, so the inbound listens on `0.0.0.0`,
  and the outbound uses `UseIPv4`.
- **Transparent proxying and TUN aren't set up.** Those need netfilter and
  routing features the kernel lacks. Plain inbounds work.

## Kernel support

No kernel options were added. Like tailscaled, it relies on the
overcommit patch that lets Go programs start.

## Log messages you can ignore

None recorded yet.
