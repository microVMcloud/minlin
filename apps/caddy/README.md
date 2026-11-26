# Caddy on minlin

This app runs the host's [Caddy](https://caddyserver.com) web server as the
only program in a minlin microVM, serving the files in `rootfs/var/www`. By
default it serves plain HTTP on port 80. Built with `CADDY_DOMAIN=`, it serves
that domain over HTTPS on port 443, with a certificate it gets and renews
itself.

## Requirements

On the host:

- Caddy (`sudo apt install caddy`). Tested with Ubuntu's 2.6.2, a ~39MB Go
  binary needing only libc. The build runs the host's `caddy adapt` to check
  the Caddyfile.
- `debugfs` (e2fsprogs, which minlin's build already needs), to copy
  certificates out of the old disk image.

For a public certificate, also:

- A domain name whose DNS points at the address the VM is reached on.
- Ports 80 and 443 on that address open to the internet and forwarded to
  the guest. The CA connects to them to check that you control the domain,
  and Caddy uses whichever of the two challenges it can.

## Build and boot

Plain HTTP:

    ./build-disk.sh caddy
    HOSTFWD=8080 ./boot-qemu.sh          # then: curl http://localhost:8080/

HTTPS, using a certificate from Caddy's own CA (no domain or internet
access needed):

    CADDY_DOMAIN=localhost ./build-disk.sh caddy
    MEM=64 HOSTFWD=8080 HTTPSFWD=8443 ./boot-qemu.sh
    curl -k https://localhost:8443/

HTTPS for a public domain, starting with Let's Encrypt's staging CA, whose
certificates browsers don't trust but which has no tight rate limits:

    CADDY_DOMAIN=example.com CADDY_EMAIL=you@example.com CADDY_STAGING=1 \
        ./build-disk.sh caddy
    MEM=64 BIND_ADDR=0.0.0.0 HOSTFWD=8080 HTTPSFWD=8443 ./boot-qemu.sh

with the router (or firewall) forwarding the public ports 80 and 443 to the
host's 8080 and 8443. Rebuild without `CADDY_STAGING` once a staging
certificate arrives. To have QEMU listen on 80 and 443 itself instead, the
host must let unprivileged users bind them
(`sudo sysctl net.ipv4.ip_unprivileged_port_start=80`). Under Firecracker the
guest has its own address on the bridge, and all its ports are reachable
there.

Build-time settings:

| Variable | Meaning |
|----------|---------|
| `CADDY_DOMAIN` | host name to serve over HTTPS. Without it, plain HTTP on port 80 |
| `CADDY_EMAIL` | optional ACME account contact, used by the CA for expiry warnings |
| `CADDY_STAGING` | `1` to use Let's Encrypt's staging CA |

`HTTPSFWD` (in `boot-qemu.sh`) forwards a host port to the guest's port 443,
on both TCP and UDP (HTTP/3). In HTTPS mode, port 80 redirects to
`https://<domain>/` with a 308, and serves the CA's HTTP challenge.

### Certificates across rebuilds

Caddy keeps its certificates, keys and ACME account in `/var/lib/caddy` on
the disk, which lasts across reboots. A rebuild would normally lose them and
have Caddy request new ones, and Let's Encrypt issues only 5 certificates a
week for the same set of names. So each build first copies `/var/lib/caddy`
out of the old `sys/diskimage` into `linux-src/caddy_data` (mode 0700),
and an HTTPS build puts it on the new disk. Only an image that holds
certificates replaces what is saved, so building another app in between
doesn't lose them. Delete `linux-src/caddy_data` to start over.

Tested with `CADDY_DOMAIN=localhost`: after a rebuild the server presented
the same certificate (same SHA-256 fingerprint), and Caddy didn't issue a
new one. A real ACME issuance is untested here.

### Killing the VM

Caddy doesn't fsync the files it writes. With the kernel's default
writeback delay of about 30 seconds, a VM killed (Ctrl-A x) soon after Caddy
first wrote its keys left them as empty files, and Caddy then exited at
every start with `parsing root certificate PEM: no PEM block found`. An
HTTPS build therefore sets `vm.dirty_expire_centisecs` and
`vm.dirty_writeback_centisecs` to 100 in `/etc/sysctl.conf`, which brings
the delay down to about a second: a VM killed 10 seconds after boot kept
non-empty files. Copying the state out of the old image also drops empty
files, and Caddy makes any missing one again.

## Memory

Measured under QEMU with KVM by booting the disk and then sending requests
for the index page with `curl` from the host (a new connection for each, so
over HTTPS a full TLS handshake each time):

| Mode | MEM | Requests, concurrent | Result |
|------|-----|----------------------|--------|
| HTTP | 32 | 1000, 10 (twice) and 50 | all OK, 6 to 8s |
| HTTP | 48 | 1000, 10 and 50 | all OK, about 6s |
| HTTPS | 48 | 300, 10 | all OK, but 29s, about ten times slower than at 56MB |
| HTTPS | 56 | 300, 10 | all OK, 2.4s |
| HTTPS | 64 | 300, 10 and 1000, 50 | all OK, 2.9s and 11.7s |

So plain HTTP runs at the default `MEM=32`, and HTTPS wants `MEM=64`.

## What's on the disk

- `/usr/bin/caddy` and its libc, `/usr/bin/env` (init.conf can't set
  variables, and `XDG_DATA_HOME`/`XDG_CONFIG_HOME` move Caddy's state from
  `/.local` and `/.config` to `/var/lib/caddy`).
- `/etc/caddy/Caddyfile`. The admin API is off. In HTTPS mode `install.sh`
  replaces `:80` with the domain and removes `auto_https off`.
- `/var/www/index.html`.
- In HTTPS mode, also `/etc/resolv.conf` (1.1.1.1 and 8.8.8.8), the host's
  `/etc/ssl/certs/ca-certificates.crt`, `/etc/sysctl.conf`, and any saved
  `/var/lib/caddy` state.

The files come to 55MB, so the default 128M image is enough.

## Kernel support

Nothing beyond what the minimal kernel already has. The guest has no IPv6,
so Caddy is reachable over IPv4 only.

## Log messages you can ignore

The access log and Caddy's own log go to the serial console, in Caddy's
console format with ANSI colours.

- `admin endpoint disabled`: set on purpose.
- `automatic HTTPS is completely disabled`: plain HTTP mode.
- `stapling OCSP ... no OCSP server specified in certificate`: certificates
  from Caddy's local CA have no OCSP server.
- `root certificate trust store installation disabled`: `skip_install_trust`
  is set, because nothing in the guest would use the trust store.
- `server is listening only on the HTTPS port but has no TLS connection
  policies; adding one`: Caddy's normal message when it sets up HTTPS.
- Each failed request (a 404, say) is logged at `ERROR` level.
