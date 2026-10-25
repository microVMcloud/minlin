# OpenSSH on minlin

This app runs the host's OpenSSH server as the only program in a minlin
microVM. Root logs in with a key to `bash`, with the everyday commands from
`apps/bash` (busybox: `ls`, `cat`, `grep`, `sed`, `ps`, `free`, `df`, ...) and the ssh
client. Interactive sessions get a real pty with job control, and `scp` and
`sftp` work.

## Requirements

On the host:

- OpenSSH (`sshd` from openssh-server; `ssh` and `ssh-keygen` from
  openssh-client). The VM gets whatever version the host has.
- bash, util-linux and busybox, for the login shell (see `apps/bash`), plus what
  minlin itself needs (see the top-level README).
- A public key to log in with. Password logins are off.

## Build and boot

    ./build-linux.sh                     # once, or after kernel/init changes
    SSH_AUTHORIZED_KEYS=~/.ssh/id_ed25519.pub ./build-disk.sh sshd
    SSHFWD=2222 ./boot-qemu.sh

Then, from the host:

    ssh -p 2222 root@localhost

- `SSH_AUTHORIZED_KEYS` names the file of public keys (an `authorized_keys`
  file or a single `.pub`) that may log in as root. It's copied to
  `/root/.ssh/authorized_keys`; the build stops if it isn't set.
- `SSHFWD` switches QEMU to user-mode networking and forwards that host port
  to the guest's port 22. It can be combined with `HOSTFWD` (port 80).

Under Firecracker the guest is on the bridge (`br0` by default) with its own
IP, so connect to that directly:

    ./boot-firecracker.sh
    ssh root@<guest IP>

sshd's log goes to the serial console.

## Host key

The ed25519 host key is generated on the first build and kept in the work
directory as `linux-src/ssh_host_ed25519_key`. Rebuilding the disk reuses it,
so clients don't see a changed host key. Delete that file to get a new one.

## Shutting down

From a session:

    kill $(cat /run/sshd.pid)

then log out. Stopping the listener doesn't end sessions that are already
open; once the last one ends, init has nothing left running, so it syncs the
disk and reboots, which ends the VM.

Avoid killing the VM instead (Ctrl-A x in QEMU): the disk is ext4, so its
journal keeps the filesystem consistent, but writes that weren't synced yet
(a login's utmp/wtmp records, say) can be lost. The next boot replays the
journal when init mounts the disk.

sshd runs as `once`, not `respawn`. With `respawn` init would never run out
of programs, so it would never sync and reboot.

## Memory

The default 32MB is enough. With one interactive session open, `free` reports
about 14MB available.

## What's on the disk

| Path | Purpose |
|------|---------|
| `/usr/sbin/sshd` | the listener |
| `/usr/lib/openssh/sshd-session`, `sshd-auth` | run for each connection: the session, and the unprivileged pre-auth side |
| `/usr/lib/openssh/sftp-server` | `sftp`, and `scp` (which uses the SFTP protocol) |
| `/usr/bin/ssh`, `/usr/bin/ssh-keygen` | the client, for ssh out of the VM |
| `/usr/bin/bash` and `/usr/bin/*` | root's login shell and commands (from `apps/bash`) |
| `/etc/profile`, `/etc/bash.bashrc` | the `root@minlin:~#` prompt (from `apps/bash`) |
| `/etc/ssh/sshd_config` | key-only root login, no PAM, no DNS lookups |
| `/etc/ssh/ssh_host_ed25519_key` | the host key (see [Host key](#host-key)) |
| `/root/.ssh/authorized_keys` | from `SSH_AUTHORIZED_KEYS` |
| `/etc/passwd`, `/etc/group` | `root`, and the `sshd` privilege separation user |
| `/run/sshd/` | empty directory that the pre-auth process is chrooted into |
| `/var/log/lastlog`, `/var/run/utmp` | login records sshd writes |
| `/usr/share/terminfo/...` | entries for common client `TERM`s (xterm, screen, tmux, ...) |

sshd refuses a privsep directory or key files that aren't owned by root, so
`build-disk.sh` makes every file on the disk root's, whoever runs the build.

The host key's private half is in `linux-src/rootfs/` and
`sys/diskimage` (both ignored by git), as well as in
`linux-src/ssh_host_ed25519_key`.

## Kernel support

`build-linux.sh` builds these into the (app-independent) kernel for sshd:

| Option | Why |
|--------|-----|
| `MULTIUSER` | sshd changes uid/gid and supplementary groups, even for root |
| `POSIX_TIMERS` | `setitimer`, for the login grace timeout; without it every connection fails with `login grace time setitimer failed` |
| `UNIX98_PTYS` | ptys for interactive sessions; init mounts devpts on `/dev/pts` |
| `FILE_LOCKING` | glibc locks utmp before recording a login; without it logouts log `logout() returned an error` |
| `SECCOMP`, `SECCOMP_FILTER` | the pre-auth process sandboxes itself with seccomp-bpf; without them every connection is closed with `ssh_sandbox_child: prctl(PR_SET_SECCOMP): Invalid argument` |

Together these cost about 70KB of free RAM at boot.

## Log messages you can ignore

- `Postponed publickey for root ... [preauth]`: the client checking that the
  server accepts its key before signing with it.
- `Connection closed by authenticating user root ... [preauth]`: a client
  that offered a key that isn't in `authorized_keys`.
