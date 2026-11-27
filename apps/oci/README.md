# Container images on minlin

This app turns a Open Container Initiative image from a registry into a minlin disk. The build pulls the image over the registry's HTTP API, unpacks its layers, and writes `etc/init.conf` so init starts what `docker run <image>` would. Docker isn't needed on the host.

## Requirements

On the host:

- `curl`, `jq`, coreutils (`sha256sum`, `realpath`) and GNU tar, plus `zstd`
  for images with zstd layers.
- `gcc` with a static libc (`sudo apt install gcc libc6-dev`), to build
  `/minlin/run` (see [What's on the disk](#whats-on-the-disk)).
- Network access to the registry. Only anonymous pulls work, which covers
  public images on Docker Hub, ghcr.io and quay.io.
- A kernel built by the current `build-linux.sh`, for images that need
  inotify or run their own scripts (see [Kernel support](#kernel-support)).

## Build and boot

    ./build-oci.sh <image>             # the same as IMAGE=<image> ./build-disk.sh oci

    ./build-oci.sh caddy:latest
    MEM=48 HOSTFWD=8080 ./boot-qemu.sh      # then: curl http://localhost:8080/

    OCI_ENV="DNSMASQ_USER=root" ./build-oci.sh pihole/pihole
    HOSTFWD=8080 DNSFWD=5353 ./boot-qemu.sh
    dig -p 5353 @127.0.0.1 doubleclick.net  # 0.0.0.0: blocked

| Variable | Meaning |
|----------|---------|
| `IMAGE` | `[registry/]repository[:tag\|@sha256:<digest>]`, Docker Hub when no registry is given. `build-oci.sh` sets it from its argument |
| `OCI_ENV` | `NAME=value` pairs, split on whitespace, that override the image's Env, like `docker run -e` |
| `OCI_PLATFORM` | the image to pick from a multi-platform index, default `linux/amd64` |
| `OCI_CMD` | replaces the image's Entrypoint and Cmd, split on whitespace |
| `OCI_ACTION` | the `init.conf` action, default `respawn` |

Blobs are kept by digest in `linux-src/oci/blobs/sha256/` and checked against
it, so a rebuild only asks the registry for the manifest. A tag such as
`latest` is resolved again on every build. Pin `@sha256:...` to keep an image
fixed. The build prints the image manifest's digest.

`DISK_SIZE` is set to 1.5 times the unpacked size plus 32MB.

The build prints a note for each port the image exposes that `boot-qemu.sh`
doesn't forward. `boot-qemu.sh` forwards guest ports 80 (`HOSTFWD`), 22
(`SSHFWD`), 5432 (`PGFWD`), 6379 (`REDISFWD`) and 53 over TCP and UDP
(`DNSFWD`). Under
Firecracker every port is reachable.

## Pi-hole

Tested with `pihole/pihole:latest` (FTL v6.9, Alpine, manifest
`sha256:52762e16...`):

    OCI_ENV="DNSMASQ_USER=root" ./build-oci.sh pihole/pihole
    HOSTFWD=8080 DNSFWD=5353 ./boot-qemu.sh

- **`DNSMASQ_USER=root` is required.** The image's `start.sh` gives
  `pihole-FTL` its capabilities with `setcap` so it can run as the `pihole`
  user. The kernel's ext4 has no security xattrs, so that fails with "Not
  supported" and `start.sh` exits, unless FTL is told to run as root. FTL
  then warns that running as root is not recommended.
- On the first boot it downloads the default blocklist (StevenBlack's hosts,
  81677 domains) and builds `gravity.db`, which needs the guest's outbound
  internet (any `*FWD` variable under QEMU). The database is kept on the disk
  for later boots.
- The admin password is random and printed on the console (`assigning random
  password`). Set your own with `OCI_ENV="DNSMASQ_USER=root
  FTLCONF_webserver_api_password=..."`, but it goes onto the disk in plain
  text. The web interface is at `/admin/` on port 80.
- Upstream DNS defaults to Google (8.8.8.8, 8.8.4.4). `FTLCONF_dns_upstreams`
  in `OCI_ENV` changes it.
- dnsmasq's `local-service` answers only clients on the guest's own subnet.
  Under QEMU those are forwarded queries, which come from 10.0.2.2. Under
  Firecracker, clients on the bridge's subnet should be fine and others would
  need `FTLCONF_dns_listeningMode=ALL`. Firecracker is untested.

Checked after boot: `doubleclick.net` answers `0.0.0.0` and `example.com`
resolves, over UDP and TCP, the login page loads, and `POST /api/auth` with
the printed password returns a valid session (at `MEM=64`). The weekly
gravity update and the rest of the web UI weren't exercised.

## How the image's config becomes init.conf

- **Entrypoint and Cmd** are joined into the command. A program named without
  a `/` is looked up on the image's `PATH`, so the build can check it's there.
- **Scripts:** when the program starts with `#!`, the build puts its
  interpreter first, so `init.conf` names an ELF binary that the build can
  check. pihole's `start.sh` is started as `/bin/bash /usr/bin/start.sh`.
- **Env and WorkingDir** go to `/minlin/run`, followed by `OCI_ENV`.
  `HOME=/root` is added unless the image sets `HOME`, as Docker does for root.
- **Quoting:** init splits lines on whitespace with no quoting. An argument
  with a space in it (`sh -c "a && b"`) fails the build, and `OCI_CMD` or a
  wrapper script is needed. An environment variable with a space in its value
  is dropped with a warning.
- **Limits:** the line must fit init's 32 arguments and 511 characters, or the
  build fails.

For `caddy:latest` this gives:

    respawn /minlin/run -C /srv PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin CADDY_VERSION=v2.11.9 XDG_CONFIG_HOME=/config XDG_DATA_HOME=/data HOME=/root -- /usr/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile

## What's on the disk

- The image's files, with its layers applied in order and their whiteouts
  (`.wh.<name>`, `.wh..wh..opq`) deleting what lower layers added.
- `/minlin/run`, built static from `src/run.c` so it runs on any image's libc
  or on none. Before it changes to the working directory, sets the variables
  and `execvp`s the command through the image's `PATH`, it does two things
  Docker would have done:
  - It makes `/tmp` mode 1777, as images ship it. init mounts a root-only
    `/tmp` over the image's, and pihole's gravity, running as the `pihole`
    user, can't create its temporary files there.
  - It points `/dev/shm` at `/minlin/shm` on the disk, after emptying it.
    `shm_open` is a file opened in `/dev/shm`. The kernel has no tmpfs, and
    init's RAM-backed `/dev` can't `fallocate`, which pihole-FTL's shared
    memory needs. ext4 can, and shared mappings of its files work the same.
    The pages are written back to the disk from time to time. Segments are
    named after pids, which repeat from boot to boot, hence the emptying.
- `/etc/resolv.conf` (1.1.1.1 and 8.8.8.8) and `/etc/hosts` (localhost), when
  the image has none. Docker writes both into every container when it runs.
- The generated `/etc/init.conf`.

## Differences from Docker

- **Everything is owned by root.** `build-disk.sh` records every file as
  root's, and the build runs as a normal user, so the owners in the layers
  are lost. Modes are kept. pihole's `start.sh` sets the owners it needs
  itself.
- **It runs as root.** The image's `USER` is ignored, with a warning. An image
  that drops privileges in its entrypoint (with `su-exec`, `gosu` or
  `setpriv`) works if it fixes the owners of what it writes, as pihole's does.
- **No file capabilities**, so `setcap` fails (see [Pi-hole](#pi-hole)).
- **No volumes, health checks, signals forwarded by `--init`, or a fresh
  container on each start.** The disk persists across boots, so state the
  program writes stays until the next build.
- **Device nodes** in a layer make tar fail, because a non-root build can't
  create them. Images rarely ship any.
- **Other kernel limits** still apply (see AGENTS.md): no IPv6, cgroups or
  `/sys`.

## Safety

Layers are untrusted and are unpacked on the host as the build user. GNU tar
strips leading `/`, refuses `..`, and holds back symlinks that point outside
the tree until the end of each archive. It still follows a symlink left by an
earlier layer, so before extracting each layer the build checks every
directory its entries pass through, hard link targets included. It refuses the
layer if one of them is a symlink that resolves outside the rootfs. Docker
would resolve an absolute symlink inside the container instead, so an image
that relies on that (an absolute `/lib -> /usr/lib`, say) is refused rather
than mis-built. Relative links, as Debian's usrmerge uses, are fine. Tested
with a symlink `evil -> /etc` followed by `evil/passwd` (refused), `lib/../../x`
(refused) and `lib -> usr/lib` (allowed). Blobs are checked against their
sha256 digests, and a manifest fetched by digest is checked too.

## Memory

Measured under QEMU with KVM, as the time from starting `boot-qemu.sh` to the
first right answer, polled every second, on a freshly built disk:

| `MEM` | Caddy: first `200` | Pi-hole: `doubleclick.net` blocked |
|-------|--------------------|------------------------------------|
| 32 | 20.3 s | 3.1 s |
| 40 | 5.7 s | 1.0 s |
| 48 | 2.1 s | about 1 s |
| 64 | about 2 s | about 1 s |

Pi-hole's time includes downloading the blocklist and building gravity.db.
Nothing was killed or restarted at any of these sizes. Caddy was measured on
the kernel without the two options above, Pi-hole on the kernel with them.
Pi-hole wasn't tested with a real query load or with larger blocklists,
which take more memory. Start higher than 32 for real use.

## Tested images

`caddy:latest` and `pihole/pihole:latest`, both from Docker Hub. zstd layers
and other registries haven't been tried. pihole's 13 layers held no
whiteouts, so that code is untested too.

## Log messages you can ignore

    WARN  failed to set GOMAXPROCS  {"error": "open /proc/self/cgroup: no such file or directory"}

The kernel has no cgroups, and Go falls back to the CPU count (Caddy).

    Failed to set capabilities on file '/usr/bin/pihole-FTL': Not supported
    WARNING: Starting pihole-FTL as user root is not recommended

Expected with `DNSMASQ_USER=root` (see [Pi-hole](#pi-hole)).

    ERROR: Error NTP server: Cannot create NTP socket (Address family not supported by protocol), IPv6 NTP server not available

The kernel has no IPv6. FTL's IPv4 NTP server still starts.

    tail: inotify cannot be used, reverting to polling: Function not implemented

Only on kernels without `INOTIFY_USER`.
