# Dropbear on minlin

This app runs the host's Dropbear SSH server as the only program in a minlin
microVM: a smaller alternative to `apps/sshd`. Root logs in with a key to
`bash`, with the everyday commands from `apps/bash` (busybox: `ls`, `cat`,
`grep`, `sed`, `ps`, `free`, `df`, ...) and Dropbear's client, `dbclient`.
Interactive sessions get a real pty with job control, and `scp` and `sftp`
work if the host has OpenSSH's `sftp-server`.

## Requirements

On the host:

- Dropbear (`dropbear`, `dropbearkey` and `dbclient` from dropbear-bin). The
  VM gets whatever version the host has.
- Optionally `/usr/lib/sftp-server` (openssh-sftp-server), for `sftp` and
  `scp`. Without it the build warns and those don't work.
- bash, util-linux and busybox, for the login shell (see `apps/bash`), plus what
  minlin itself needs (see the top-level README).
- A public key to log in with. Password logins are off.

## Build and boot

    ./build-linux.sh                     # once, or after kernel/init changes
    SSH_AUTHORIZED_KEYS=~/.ssh/id_ed25519.pub ./build-disk.sh dropbear
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

Dropbear's log goes to the serial console.

## Host key

The ed25519 host key is generated with `dropbearkey` on the first build and
kept in the work directory as `linux-src/dropbear_ed25519_host_key` (in
Dropbear's own format; `dropbearconvert` turns it into an OpenSSH one).
Rebuilding the disk reuses it, so clients don't see a changed host key.
Delete that file to get a new one. It is separate from the `sshd` app's key,
so switching between the two apps changes the host key clients see.

## Shutting down

From a session:

    kill $(cat /var/run/dropbear.pid)

then log out. Stopping the listener doesn't end sessions that are already
open; once the last one ends, init has nothing left running, so it syncs the
disk and reboots, which ends the VM.

Avoid killing the VM instead (Ctrl-A x in QEMU): the disk is ext4, so its
journal keeps the filesystem consistent, but writes that weren't synced yet
can be lost. The next boot replays the journal when init mounts the disk.

dropbear runs as `once`, not `respawn`. With `respawn` init would never run
out of programs, so it would never sync and reboot.

## Memory

The default 32MB is enough. With one session open, `free` reports about 16MB
available, a little more than with OpenSSH.

## What's on the disk

| Path | Purpose |
|------|---------|
| `/usr/sbin/dropbear` | the server (one process per connection, no helpers) |
| `/usr/bin/dropbearkey`, `/usr/bin/dbclient` | key generation, and the client for ssh out of the VM |
| `/usr/lib/sftp-server` | `sftp`, and `scp` (which uses the SFTP protocol), if the host has it |
| `/usr/bin/bash` and `/usr/bin/*` | root's login shell and commands (from `apps/bash`) |
| `/etc/profile`, `/etc/bash.bashrc` | the `root@minlin:~#` prompt (from `apps/bash`) |
| `/etc/dropbear/dropbear_ed25519_host_key` | the host key (see [Host key](#host-key)) |
| `/root/.ssh/authorized_keys` | from `SSH_AUTHORIZED_KEYS` |
| `/etc/shells` | dropbear only lets in users whose shell is listed here |
| `/etc/resolv.conf` | DNS via 1.1.1.1 and 8.8.8.8, for `ping`, `dbclient` and the like by name |
| `/etc/passwd`, `/etc/group` | just `root`; dropbear has no privilege separation user |
| `/var/run/utmp`, `/var/log/wtmp`, `/var/log/lastlog` | login records dropbear writes |
| `/usr/share/terminfo/...` | entries for common client `TERM`s (xterm, screen, tmux, ...) |

The options are on the command line in `/etc/init.conf` rather than in a
config file: `-s` turns off password logins and `-m` skips the motd.

dropbear refuses a key login if `/root`, `/root/.ssh` or `authorized_keys`
can be written by anyone but root, so `install.sh` sets their modes rather
than leaving them to the build's umask, and `build-disk.sh` makes every file
on the disk root's, whoever runs the build.

The host key's private half is in `linux-src/rootfs/` and
`sys/diskimage` (both ignored by git), as well as in
`linux-src/dropbear_ed25519_host_key`.

## Kernel support

Dropbear needs nothing beyond what `build-linux.sh` already enables for
`apps/sshd`: `MULTIUSER`, `UNIX98_PTYS` for sessions (init mounts devpts on
`/dev/pts`) and `FILE_LOCKING` for utmp. It doesn't sandbox itself, so it
doesn't need `SECCOMP`.

## Known problem

`ssh -t host command` (a pty for a single command, rather than a login
shell) gets no output, and dropbear logs `ioctl(TIOCSCTTY): Input/output
error`. Dropbear 2025.89 does the same on a full Ubuntu host, so this is
Dropbear's problem, not minlin's. Plain logins and commands without `-t` work.
