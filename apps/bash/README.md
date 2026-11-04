# bash on minlin

This app runs the host's `bash` as the only program in a minlin microVM, on
the serial console, with the host's busybox for the everyday commands. It has
job control and a working Ctrl-C, and `exit` (or Ctrl-D) ends the VM.

`apps/sshd` uses this app's `install.sh` for its login shell, so everything
here applies to ssh sessions too.

## Requirements

On the host:

- bash, and util-linux for `setsid`.
- busybox (`busybox-static`).
- curl, and `ca-certificates` for its CA roots.
- What minlin itself needs (see the top-level README).

## Build and boot

    ./build-linux.sh                     # once, or after kernel/init changes
    ./build-disk.sh bash
    ./boot-qemu.sh

The console is QEMU's stdio. Type `exit` or Ctrl-D to leave bash, which ends
the VM. `GUEST_NAME=` sets the hostname shown in the prompt.

## Prompt

`/etc/bash.bashrc` sets a Debian-style prompt, `user@host:dir` followed by
`#` for root or `$` for anyone else, with the user and host in green and the
directory in blue:

    root@minlin:/usr/bin#

Interactive shells read `/etc/bash.bashrc` directly. Login shells (ssh
sessions) read `/etc/profile`, which loads it. On the console, init sets
`HOME=/`, so the shell starts in `/` rather than `~`.

## Commands

Apart from bash's builtins, the commands come from the host's busybox.
`install.sh` copies the one binary to `/usr/bin/busybox` and links every
applet it was built with (`busybox --list`) to it, so the disk has whatever
the host's busybox has: `ls`, `cat`, `cp`, `grep`, `sed`, `awk`, `find`,
`tar`, `ps`, `top`, `free`, `df`, `vi`, `less`, `stty`, `ip`, `wget`, ...
Debian/Ubuntu's `busybox-static` (about 2MB) needs no shared libraries.

`curl` is the host's, with its shared libraries and the CA bundle for
`https://`. The guest only has outbound internet under QEMU if the VM boots
with `HOSTFWD` or `SSHFWD`, even if nothing listens on the forwarded port:

    HOSTFWD=8080 ./boot-qemu.sh

A command already on the disk when the links are made keeps its real
version: `bash` and util-linux `setsid` (busybox's has no `-w`). For any
other command you want the host's version of instead, `install_binary` it
before the busybox loop in `install.sh`.

## Controlling terminal

init starts each program in a new session with no controlling terminal.
Without one, bash prints `cannot set terminal process group` and runs
without job control, and Ctrl-C can't interrupt a command. So
`/etc/init.conf` starts bash through util-linux `setsid -c`, which makes the
console bash's controlling terminal:

    once /usr/bin/setsid -c -w /usr/bin/bash -i

`-w` makes setsid wait for bash, so init sees the shell exit.

## Terminal

The kernel starts init with `TERM=linux`, which init passes on to bash.
readline needs that terminal's terminfo entry for line editing, so it's
copied from the host. A serial console can't report its size, so bash
assumes 80x24, and lines longer than the real window wrap oddly when
edited. Set the real size with busybox's `stty`, e.g. `stty rows 50 cols 160`.

## Memory

The disk holds 26MB: bash and its libraries, setsid, busybox, and curl, whose
libraries are about 20MB of that. The default 32MB of RAM is plenty: with bash
at its prompt, `free` reports about 19MB available, and an `https://` fetch
works.

## What's on the disk

| Path | Purpose |
|------|---------|
| `/usr/bin/bash` | the host's bash |
| `/usr/bin/setsid` | gives bash the console as its controlling terminal |
| `/usr/bin/curl` | the host's curl |
| `/usr/bin/busybox` | the everyday commands |
| `/usr/bin/*` | links to busybox, one per applet |
| `/etc/init.conf` | starts bash on the console |
| `/etc/bash.bashrc`, `/etc/profile` | the prompt |
| `/etc/passwd` | `root`, so the prompt can show a user name |
| `/etc/resolv.conf` | DNS via 1.1.1.1 and 8.8.8.8, for `curl` and the like by name |
| `/etc/ssl/certs/ca-certificates.crt` | CA roots for `curl` |
| `/usr/share/terminfo/l/linux` | the console's terminfo entry |
| `/lib64/`, `/usr/lib/x86_64-linux-gnu/` | shared libraries the programs need |

The disk is writable. bash saves its history to `/.bash_history` on exit, so
it carries over to the next boot until the disk is rebuilt. Killing the VM
(Ctrl-A x in QEMU) instead of typing `exit` skips that save and the final
sync; ext4's journal keeps the disk consistent, but unsynced writes are lost.

## Kernel support

bash needs nothing beyond the options every app uses: it ran on the kernel
before the sshd options were added.
