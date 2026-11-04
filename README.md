# minlin

MINimal LINux

## Summary

A tiny x86-64 Linux kernel (tinyconfig plus virtio-mmio) with a custom `init.c` built into its initramfs, booting under QEMU microvm or Firecracker and running ordinary, dynamically linked Linux programs from an ext4 disk.

| Linux 7.2.15 (booted with 64 MiB RAM) | minlin | Full |
| -------- | -------- | -------- |
| bzImage (bytes) | 1,745,920 | 15,270,912 |
| vmlinux (bytes) | 13,012,472 | 53,905,608 |
| Free Memory (KiB) | 49,384 | 10,704 |
| Startup time (seconds) | 0.010732 | 2.911762 |

Measured under QEMU microvm (`boot-qemu.sh`, `MEM=64`), median of five boots: free memory is `MemFree` from `/proc/meminfo` as the first program runs, and startup time is the kernel timestamp of "Run /init as init process". Most of the full kernel's startup time is spent probing for an RTC, which microvm doesn't have.

This project started based on this [blog post](https://nick.zoic.org/art/boot-naked-linux/) and is very similar to other Linux "Unikernel" projects.

minlin is the default Linux kernel used at [microVM Cloud](https://microvmcloud.com).

## Build and boot

    ./build-linux.sh                 # sys/bzImage + sys/vmlinux, init built in
    ./build-disk.sh lighttpd         # sys/diskimage for apps/lighttpd
                                     # (or: python / top / bash / sshd /
                                     #  dropbear / tailscale / lightpanda /
                                     #  node)
    HOSTFWD=8080 ./boot-qemu.sh      # then: curl http://localhost:8080/
                                     # (SSHFWD=2222 for ssh -p 2222 root@localhost)
    ./boot-firecracker.sh            # tap on br0; guest gets the next IP up
                                     # (both take MEM=<MB>, default 32,
                                     #  and GUEST_NAME=, default minlin)

`boot-firecracker.sh` also takes `HUGEPAGES=1` to back guest RAM with 2MB huge pages, which makes the kernel boot about three times faster (minlin reaches `/init` in ~0.007s instead of ~0.024s). Reserve MEM/2 pages per VM on the host first, e.g. `sudo sysctl vm.nr_hugepages=64` for `MEM=128`; the script checks there are enough free before it starts.

The kernel doesn't depend on the app, so switching apps only needs `build-disk.sh` re-run. The lighttpd app needs `lighttpd` installed on the host (`sudo apt install lighttpd`); the host's binary, its modules and shared libraries (found with `ldd`) are copied into the disk image.

## Boot sequence

1. The kernel runs `/init` from the built-in initramfs.
2. init brings up the loopback interface (`lo`, 127.0.0.1), then configures `eth0`, and the hostname if given, from the `ip=` kernel parameter.
3. init mounts `/dev/vda` (ext4), moves it over `/` and chroots into it, then mounts `/dev`, `/dev/pts`, `/proc` and `/tmp` there.
4. init turns on swap on every block device (whole disk or partition) that has a swap signature from `mkswap`.
5. init applies `/etc/sysctl.conf` if the disk has one (`key = value` lines, as for `sysctl -p`).
6. init runs the programs listed in `/etc/init.conf`, reaps children, and reboots (ending the VM) once nothing is left running.

## Swap

Both boot scripts take `SWAP=<file>` to attach a swap image as a second disk (`/dev/vdb`), which init finds and swaps onto:

    fallocate -l 256M sys/swapimage && chmod 600 sys/swapimage && mkswap sys/swapimage
    SWAP=sys/swapimage ./boot-qemu.sh

The root disk must stay a whole-disk ext4 image at `/dev/vda`, so swap goes on its own disk. The minlin kernel has no partition-table parsers, so it only sees swap on a whole disk; the full kernel also finds swap partitions.

## Apps

Each directory in `apps/` is something the VM can run. `build-disk.sh <app>` builds the disk from it:

- `rootfs/` is copied onto the disk as-is (everything owned by root). It
  should hold `etc/init.conf`, which says what init starts. Each line is
  `<wait|once|respawn> /absolute/path [args...]`.
- `install.sh` (optional) is sourced afterwards. It can call
  `install_binary /path/on/host` to copy a host program and the shared
  libraries it needs onto the disk, `require <cmd> [apt-package]` to check the
  host has something, copy anything else into `$ROOTFS`, and set `DISK_SIZE`
  if the default 128M is too small.

### lighttpd

`apps/lighttpd` serves `rootfs/var/www` on port 80 with its access log on the
console.

### python

`apps/python` runs `rootfs/app/main.py` with the host's `python3` (so the host
needs Python 3): a small `http.server` on port 80 that reports the Python
version, kernel and boot parameters, memory (from `/proc/meminfo`) and disk
space, as HTML at `/` and as JSON at `/metrics.json`. Its standard library is
copied too, minus the test suite, GUI packages and the static libpython, along
with the shared libraries its extension modules (ssl, sqlite3, ...) link
against.

### node

`apps/node` runs `rootfs/app/server.js` with the host's `node`, a small web
server on port 80. It expects Debian/Ubuntu's `nodejs` package (tested with
22.22.1): that build keeps some of its JavaScript in `/usr/share/nodejs`,
loaded at startup, so `install.sh` copies those files too. The disk holds
127MB, so it is 256MB. Give the VM `MEM=64`: the first response takes about
0.5s, against 3.8s at 48MB, and at 40MB or less node hangs without logging an
error (no response in 45s at 40MB, or in 90s at the default 32MB).

    ./build-disk.sh node
    MEM=64 HOSTFWD=8080 ./boot-qemu.sh

### top

`apps/top` runs the host's `top` (procps) on the serial console, along with
the `linux` terminfo entry it draws with (the kernel starts init with
`TERM=linux`). Press `q` to quit top, which also ends the VM.

### bash

`apps/bash` runs an interactive `bash` on the serial console, with a
`user@host:dir` prompt (set in `/etc/bash.bashrc`) and the host's static
busybox for the everyday commands (`ls`, `cat`, `grep`, `sed`, `awk`, `ps`,
`free`, `df`, `vi`, ...), one link per applet. init starts programs with no
controlling terminal, so it goes through util-linux `setsid -c` to make the
console bash's controlling tty; that gives job control and a working Ctrl-C.
`exit` or Ctrl-D ends the VM. See
[apps/bash/README.md](apps/bash/README.md) for the details.

### sshd

`apps/sshd` runs the host's OpenSSH server (with the client too) and logs to
the console, with `bash` and the commands from `apps/bash` as root's login
shell. Root logs in with a key: `SSH_AUTHORIZED_KEYS` names the public key
file (a single `.pub` or a whole `authorized_keys` file) to put in
`/root/.ssh/authorized_keys`. If it isn't set, the disk gets an empty
`authorized_keys` instead, for a "public" image with no one's keys in it. The ed25519
host key is generated on the first build and kept in the work directory
(`linux-src/ssh_host_ed25519_key`), so it survives rebuilding the disk:

    SSH_AUTHORIZED_KEYS=~/.ssh/id_ed25519.pub ./build-disk.sh sshd
    SSHFWD=2222 ./boot-qemu.sh       # then: ssh -p 2222 root@localhost

To shut it down, run `kill $(cat /run/sshd.pid)` in a session and log out:
init reboots once the last session ends. Killing the VM instead can lose
recent writes that weren't synced to the disk yet. See
[apps/sshd/README.md](apps/sshd/README.md) for the details.

### dropbear

`apps/dropbear` is the same, with the host's Dropbear SSH server (and its
`dbclient`) in place of OpenSSH: a single process per connection, no
privilege separation user and a bit more free memory. It takes
`SSH_AUTHORIZED_KEYS` the same way, keeps its own host key in
`linux-src/dropbear_ed25519_host_key`, and uses OpenSSH's `sftp-server` for
`scp` and `sftp` if the host has it:

    SSH_AUTHORIZED_KEYS=~/.ssh/id_ed25519.pub ./build-disk.sh dropbear
    SSHFWD=2222 ./boot-qemu.sh       # then: ssh -p 2222 root@localhost

Shut it down with `kill $(cat /var/run/dropbear.pid)` and log out. See
[apps/dropbear/README.md](apps/dropbear/README.md) for the details.

### tailscale

`apps/tailscale` runs the host's `tailscaled` with kernel-mode networking (a
`tailscale0` TUN device and policy routing; IPv4 only), using 1.1.1.1 and
8.8.8.8 for DNS. Build it with an auth key, ideally an ephemeral one, and give
the VM more than the default 32MB, which thrashes paging in the ~30MB binary.
See [apps/tailscale/README.md](apps/tailscale/README.md) for the details:

    TS_AUTHKEY=tskey-auth-... ./build-disk.sh tailscale
    MEM=64 HOSTFWD=8080 ./boot-qemu.sh

With `TS_EXIT_NODE=1` it also advertises itself as an exit node (approve it in
the admin console), turning on IPv4 forwarding and NAT with nftables. Exit
traffic is IPv4 only, so tailscaled warns that IP forwarding is disabled: that
is IPv6 forwarding, which the guest doesn't have.

### lightpanda

`apps/lightpanda` runs [Lightpanda](https://lightpanda.io), a headless
browser with a JavaScript engine (V8), as an MCP server on port 80, so an AI
agent can browse the web from inside a throwaway VM. Lightpanda isn't
packaged: install it from its site (the build looks for `lightpanda` on the
`PATH`, or set `LIGHTPANDA=/path/to/binary`). It is a single ~77MB binary
needing only libc, and it starts with telemetry turned off. lighttpd sits in
front of it and only lets in clients with a bearer token, which the build
generates and keeps in `linux-src/lightpanda_mcp_token` (or set
`MCP_TOKEN=`). Give it 128MB: heavy pages leave a 64MB guest short of
network buffers. See
[apps/lightpanda/README.md](apps/lightpanda/README.md) for the details:

    ./build-disk.sh lightpanda
    MEM=128 HOSTFWD=8080 ./boot-qemu.sh
    claude mcp add --transport http minlin-browser http://localhost:8080/mcp \
        --header "Authorization: Bearer $(cat linux-src/lightpanda_mcp_token)"

### Adding an app

To add another app, create `apps/<name>/` with a `rootfs/etc/init.conf` and an
`install.sh` that installs whatever it needs (see [AGENTS.md](AGENTS.md)). The
kernel is still very small (for example no `CONFIG_SHMEM` or `CONFIG_IPV6`), so
some programs will need more kernel options enabled in `build-linux.sh`.
