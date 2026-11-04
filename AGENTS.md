# AGENTS.md

minlin is a tiny x86-64 Linux kernel with a custom init (`init.c`) built into
its initramfs. It boots under QEMU microvm or Firecracker and runs one "app":
ordinary Linux programs copied from the host onto an ext4 disk image.

`README.md` describes the project and each existing app. This file covers how
to work in the repo and how to add new apps.

## Layout

| Path | Purpose |
|------|---------|
| `init.c` | PID 1: sets up networking, mounts the disk, runs `/etc/init.conf` |
| `build-linux.sh` | builds the minimal kernel, with init inside it |
| `build-linux-full.sh` | builds a defconfig kernel with the same init, for comparison and debugging |
| `build-disk.sh <app>` | builds the disk image for `apps/<app>/` |
| `boot-qemu.sh`, `boot-firecracker.sh` | boot `sys/` under each VMM |
| `apps/<app>/` | one directory per app |
| `sys/` | build output: `bzImage`, `vmlinux`, `diskimage` (ignored by git) |
| `linux-src/` | work directory: kernel trees, `rootfs/`, kept keys and tokens (ignored by git) |

## Commands

Run these from the repo root: the work directory defaults to `$PWD/linux-src`.

    ./build-linux.sh                 # kernel and init; only after kernel or init changes
    ./build-disk.sh <app>            # disk image; all that switching apps needs
    MEM=64 HOSTFWD=8080 ./boot-qemu.sh
    timeout 30 ./boot-qemu.sh        # non-interactive run, stops a VM that never exits
    ./boot-qemu.sh --debug           # show kernel messages

Boot settings are environment variables:

| Variable | Scripts | Meaning |
|----------|---------|---------|
| `MEM` | both | guest RAM in MB, default 32 |
| `GUEST_NAME` | both | hostname |
| `SWAP` | both | a `mkswap` file to attach as `/dev/vdb` |
| `HOSTFWD`, `SSHFWD` | QEMU | host ports to forward to guest ports 80 and 22. Either one also gives the guest outbound internet through user-mode networking |
| `BRIDGE`, `TAP`, `GUEST_IP`, `HUGEPAGES` | Firecracker | see the comments in `boot-firecracker.sh` |

In QEMU, Ctrl-A x kills the VM. A killed VM skips init's final sync, so recent
writes to the disk can be lost.

There is no test suite. To verify a change, boot it and observe the result on
the serial console or over the network.

## Before changing build output

- `sys/diskimage` is a single file that every `build-disk.sh` overwrites, and a
  running VM may be using it. Check with `pgrep -a 'qemu|firecracker'` first.
- `build-linux-full.sh` replaces the minimal kernel in `sys/`. Run
  `build-linux.sh` afterwards to restore it.
- `build-linux.sh` deletes the kernel tree and rebuilds from scratch every time.
- QEMU uses fixed ports (monitor on 8086, plus 1234 without `HOSTFWD`/`SSHFWD`),
  so only one VM runs at a time from an unmodified script.

To experiment without touching the user's image, work from a copy. `sys/` is
found relative to the script, and the work directory relative to `$PWD`:

    mkdir -p "$SCRATCH/sys"
    cp build-disk.sh boot-qemu.sh "$SCRATCH/"
    cp -a apps "$SCRATCH/"
    cp sys/bzImage "$SCRATCH/sys/"
    cd "$SCRATCH" && ./build-disk.sh <app> && timeout 30 ./boot-qemu.sh

## Secrets

Disk images and `linux-src/rootfs/` can hold auth keys, tokens and host keys in
plain text. Pass secrets in through environment variables at build time, and
keep anything that must survive a rebuild in `$WORKDIR` (see `apps/lightpanda`
and `apps/sshd`). Never commit them to `apps/`.

## Adding an app

An app is a directory holding either or both of:

    apps/<name>/
        rootfs/etc/init.conf    what init starts (required in practice)
        rootfs/...              files copied onto the disk as-is, owned by root
        install.sh              optional, sourced by build-disk.sh after the copy
        README.md               optional, for anything beyond a simple app

### Worked example: Node.js

This is `apps/node`, built and booted using Ubuntu's `nodejs` 22 package.
The data files and sizes below are specific to that package.

`apps/node/rootfs/etc/init.conf`:

    respawn /usr/bin/node /app/server.js

`apps/node/rootfs/app/server.js`:

    require('http').createServer((req, res) => {
        console.log(req.method, req.url);
        res.end(`hello from node ${process.version} on ${require('os').release()}\n`);
    }).listen(80);

`apps/node/install.sh`:

    # Sourced by build-disk.sh: installs the host's node, its shared libraries,
    # and the JavaScript files Debian/Ubuntu's build loads at startup.

    require node nodejs

    install_binary "$(command -v node)"
    # Not linked in, so ldd can't see them. Found with strace on the host.
    for dep in acorn acorn-walk cjs-module-lexer minimatch undici; do
        cp -rL --parents "/usr/share/nodejs/$dep" "$ROOTFS"
    done

    DISK_SIZE=256M

Then:

    ./build-disk.sh node
    MEM=64 HOSTFWD=8080 ./boot-qemu.sh     # then: curl http://localhost:8080/

Getting there took three iterations, which is typical:

1. `mkfs.ext4` ran out of space, because the program and its libraries came to
   124MB. Fix: set `DISK_SIZE`.
2. node aborted with `Cannot load externalized builtin`, and init restarted it
   every second. Fix: trace the files it opens on the host (see
   [Debugging](#debugging)) and copy them.
3. At the default `MEM=32` it hung with no error, and never answered in 90
   seconds. It didn't answer in 45 seconds at 40MB either, took 3.8 seconds at
   48MB and 0.5 seconds at 64MB. Fix: `MEM=64`.

### Steps

1. **Check the kernel can run it.** See [Kernel limits](#kernel-limits). Running
   `strace -f <program>` on the host and looking for calls in that list is a
   quick first check.
2. **Write `rootfs/etc/init.conf`.** See [init.conf](#initconf).
3. **Write `install.sh`** to bring in the program and everything it loads at
   runtime. See [install.sh](#installsh).
4. **Add the files the program expects.** See
   [What the disk doesn't have](#what-the-disk-doesnt-have).
5. **Boot it and fix what fails.** Start with more RAM than you expect to need.
6. **Find the memory floor.** Try lower `MEM` values and record what works. Low
   memory often shows up as slowness or timeouts, not as a clear error.
7. **Document it.** Add a paragraph to the Apps section of `README.md` and add
   the app to the list in its "Build and boot" block. Anything more involved
   gets `apps/<name>/README.md`; existing ones use the sections Requirements,
   Build and boot, Memory, What's on the disk, Kernel support, and Log messages
   you can ignore.

### init.conf

Each line is `<action> /absolute/path [args...]`, and lines starting with `#`
are comments. Entries start in order.

| Action | Behavior | Use for |
|--------|----------|---------|
| `wait` | run it and wait for it to exit | setup steps. A failure doesn't stop the boot |
| `once` | start it and leave it running | jobs, shells, and services that should end the VM when they stop |
| `respawn` | start it, and restart it a second after it exits | long-running services |

When no processes are left, init syncs the disk and reboots, which ends the VM.
A `respawn` entry therefore keeps the VM up until it is killed or receives a
shutdown signal.

- **Scripts can't be executed directly.** The kernel has no `BINFMT_SCRIPT`, so
  `#!` fails with `Exec format error`. Name the interpreter:
  `once /usr/bin/bash /app/start.sh`.
- **The path must be absolute.** init uses `execv` and does not search `PATH`.
- **There is no shell and no quoting.** Arguments split on whitespace, with no
  variable expansion or redirection.
- **Limits:** 16 entries, 32 arguments per entry, 511 characters per line.
- **Environment:** programs get `PATH`, `HOME=/`, `TERM=linux`, and any kernel
  command line parameters the kernel passes on, such as `ip=`. To set others, go
  through `env` as `apps/lightpanda` does:
  `respawn /usr/bin/env FOO=bar /usr/bin/prog`.
- **Stay in the foreground.** A service that daemonizes looks like an exit to
  `respawn`. Use its foreground flag (`-D`, `-F`) and log to stdout or stderr,
  which go to the serial console.
- **No controlling terminal.** Each program starts in its own session. An
  interactive program needs `setsid -c -w`, as in `apps/bash`.

Existing `init.conf` files start with a comment block explaining the format;
copy it into new ones.

### install.sh

The script is sourced by `build-disk.sh` under `set -euo pipefail`, so a failing
command aborts the build. It starts with a comment that begins
`# Sourced by build-disk.sh:`, and it isn't executable.

| Name | Meaning |
|------|---------|
| `install_binary <path>` | copy a host file to the same path on the disk, along with everything `ldd` reports |
| `require <cmd> [apt-pkg]` | fail with an install hint if the host lacks a command |
| `log <msg>` | print a progress line |
| `$ROOTFS` | the tree that becomes the disk. It is deleted at the start of each build |
| `$WORKDIR` | `linux-src/`, which survives rebuilds. Keep generated keys here |
| `$APP`, `$APP_DIR` | the app's name and directory |
| `$SCRIPT_DIR` | the repo root |
| `DISK_SIZE` | image size, default `128M`. Set it when the files need more |

Common patterns:

- **Host program:** `install_binary "$(command -v prog)"`. The disk path matches
  the host path, so `init.conf` must use that same path. Check
  `linux-src/rootfs/` if unsure.
- **Plugins and `dlopen`ed libraries:** `ldd` can't see these. Pass each to
  `install_binary` so its own dependencies come too (`apps/lighttpd` does this
  for modules, `apps/python` for extension modules).
- **Data files:** `cp -a --parents /host/path "$ROOTFS"`, or add `-L` to follow
  symlinks, which won't resolve if their targets aren't also copied.
- **Host program at a fixed path:** copy it, then install its libraries, as
  `apps/lightpanda` does:

      mkdir -p "$ROOTFS/usr/bin"
      cp -L "$PROG" "$ROOTFS/usr/bin/prog"
      ldd "$PROG" | { grep -o '/[^ ]*' || true; } | while read -r lib; do
          install_binary "$lib"
      done

- **Compiled from source in the app:** build into `$ROOTFS` with
  `gcc -static -o "$ROOTFS/usr/local/bin/prog" "$APP_DIR/src/prog.c"` after a
  `mkdir -p`. `install_binary` can't help here because the file isn't at its
  disk path on the host. For a dynamic build, use the `ldd` loop above.
- **Reusing another app:** `source "$SCRIPT_DIR/apps/bash/install.sh"` adds bash,
  busybox and terminfo (`apps/sshd` does this). Only `install.sh` is reused:
  another app's `rootfs/` isn't copied unless you copy it yourself.
- **Shrinking the disk:** `strip` large binaries (`apps/tailscale`) and delete
  what a headless VM won't use (`apps/python`).

`.gitignore` covers patterns such as `*.so`, `*.a`, `*.o` and `*.out`, so files
with those names under `apps/` won't be committed unless forced. Prefer
generating them in `install.sh`.

### What the disk doesn't have

The disk starts empty, and only what you add is there. At boot, init adds
`/dev` (with `/dev/fd` and `/dev/std*`), `/dev/pts`, `/proc` and `/tmp`. Anything
else the program needs must come from `rootfs/` or `install.sh`:

| Needed for | Add |
|------------|-----|
| DNS | `/etc/resolv.conf` (see `apps/tailscale`) |
| TLS | `/etc/ssl/certs/` |
| User and group lookups | `/etc/passwd`, `/etc/group` |
| Terminal programs | a terminfo entry, for `linux` on the console (see `apps/top`) |
| Pid files, state | `/run`, `/var/run`, `/var/log` and so on, which don't exist unless created |
| Shell commands, including `/bin/sh` | a shell, plus busybox (see `apps/bash`) |
| Kernel settings | `/etc/sysctl.conf`, which init applies before starting programs |

Other things to expect:

- `/tmp` is RAM-backed and counts against guest memory. Its mode is 0755, so
  only root can write to it. Programs run as root unless they drop privileges.
- The disk is writable and persists across boots, until the next `build-disk.sh`.
- There is one CPU (no `SMP`), and no kernel modules. Everything must be built in.

### Networking

init configures `lo` and `eth0` before starting programs, so there's no need
for `ip` or DHCP. The address comes from the boot script's `ip=` parameter.

QEMU forwards only guest ports 80 and 22, so have the app listen on one of those
(as root, it can) or add a `hostfwd` to `boot-qemu.sh`. Under Firecracker the
guest has its own address on the bridge, and all its ports are reachable.

## Kernel limits

The kernel starts from tinyconfig, so much of what programs commonly use is
missing. These were confirmed missing by probing a booted guest or by reading
the built kernel's `.config`:

| Missing | Symptom | Option |
|---------|---------|--------|
| `#!` scripts | `Exec format error` | `BINFMT_SCRIPT` |
| `timerfd_*` | `ENOSYS` | `TIMERFD` |
| `signalfd` | `ENOSYS` | `SIGNALFD` |
| `inotify_*` | `ENOSYS` | `INOTIFY_USER` |
| `memfd_create`, real tmpfs, `/dev/shm` | `ENOSYS`, or no such file | `SHMEM`, `TMPFS` |
| System V IPC (`shmget` etc.) | `ENOSYS` | `SYSVIPC` |
| `io_uring` | `ENOSYS` | `IO_URING` |
| Linux AIO (`io_setup`) | `ENOSYS` | `AIO` |
| `membarrier` | `ENOSYS` | `MEMBARRIER` |
| `rseq` | `ENOSYS`; glibc copes | `RSEQ` |
| `bpf` | `ENOSYS` | `BPF_SYSCALL` |
| IPv6 | `EAFNOSUPPORT` | `IPV6` |
| Raw packet sockets | `EAFNOSUPPORT` | `PACKET` |
| Namespaces, containers | `EINVAL` from `unshare` | `NAMESPACES` |
| Cgroups | nothing to mount | `CGROUPS` |
| `/sys` | no such directory | `SYSFS` |
| Core dumps | none written | `COREDUMP` |
| Multiple CPUs | one CPU seen | `SMP` |

Many programs handle a missing feature themselves, as node does here, so test
before adding anything. Available and already used by the apps: `FUTEX`,
`EPOLL`, `EVENTFD`, `UNIX`, `TUN`, `MULTIUSER`, `POSIX_TIMERS`, `FILE_LOCKING`,
`SECCOMP_FILTER`, `ADVISE_SYSCALLS`, ptys, and nftables NAT. Overcommit is
patched to "always" so Go programs can start.

### Adding a kernel option

The kernel is shared by every app, so each option costs all of them memory.
Prefer changing the app, for example with a flag that avoids the feature or by
naming an interpreter instead of enabling `BINFMT_SCRIPT`.

If the option is needed:

1. Add it to `configure_kernel` in `build-linux.sh`, with a comment naming the
   app and saying why it needs the option, as the existing entries do.
2. Run `./build-linux.sh`, then confirm the option stuck:
   `grep CONFIG_FOO linux-src/linux/.config`. `olddefconfig` silently drops an
   option whose dependencies aren't met, so a missing line means enabling those
   as well.
3. Compare `mem: N KiB free` in the boot banner before and after, and report the
   difference. Small free memory is the point of this project.
4. List the option under Kernel support in the app's README.

To check whether a failure is kernel-related at all, run `./build-linux-full.sh`
and boot the same disk with `MEM=64` or more. If the app works there, the
minimal kernel is missing an option. Rebuild the minimal kernel afterwards.

`build-linux-full.sh` has its own option list and patches, as well as its own
`KERNEL_VERSION`. Keep shared changes in both scripts. Changes to `init.c` also
need a kernel rebuild, because init is built into the kernel.

## Debugging

| Symptom on the console | Likely cause |
|------------------------|--------------|
| `init: exec X: Exec format error` | `X` is a script: name its interpreter |
| `init: exec X: No such file or directory` | wrong or relative path, or its dynamic loader is missing |
| `mount /dev/vda: Invalid argument` | the image is bad, usually because `mkfs.ext4` failed for lack of space. Raise `DISK_SIZE` |
| `error while loading shared libraries` | a library `ldd` didn't report |
| The same `started`/`exited` lines repeating every second | a `respawn` program is crash-looping. Read the first error above the loop |
| `Function not implemented`, `ENOSYS`, `Address family not supported` | see [Kernel limits](#kernel-limits) |
| Very slow start, timeouts, no response, `page allocation failure` | too little RAM. Raise `MEM` |
| Name resolution or TLS failures | missing `/etc/resolv.conf` or certificates, or no `HOSTFWD`/`SSHFWD` under QEMU |
| VM exits immediately | every program has exited. Read their exit statuses |

To find the files a program needs, trace it on the host:

    strace -f -e trace=openat,newfstatat -e status=successful prog 2>&1 |
        grep -oE '"/[^"]+"' | tr -d '"' | sort -u

To see what fails inside the guest, put `strace` on the disk and start the
program through it, using a `/usr/bin/strace -f /usr/bin/prog` entry in
`init.conf` and `install_binary "$(command -v strace)"` in `install.sh`. It runs
on the minimal kernel. Delete the entry and the install line when finished.

For a look around, add `source "$SCRIPT_DIR/apps/bash/install.sh"` to the app and
temporarily add `once /usr/bin/setsid -c -w /usr/bin/bash -i` to `init.conf`.
That gives you a shell on the console alongside the app.

## Conventions

- Keep things small. Copy only what the program uses, and measure RAM and disk
  use when they change.
- Scripts are bash with `set -euo pipefail`, and they check prerequisites with
  an install hint for Debian/Ubuntu.
- Comments explain why something is needed (what breaks without it), not what
  the line does.
- Each app configures its own behavior through environment variables at build
  time, and these are documented in the comment at the top of `install.sh`.
- Numbers in docs should be measured, along with how they were measured. Say so
  when something is untested.
