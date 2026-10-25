# Sourced by build-disk.sh: installs the host's Dropbear SSH server (and its
# dbclient), along with bash and the everyday commands from apps/bash as the
# login shell.
#
# Set SSH_AUTHORIZED_KEYS to a file of public keys (an authorized_keys file
# or a single .pub) allowed to log in as root; it is copied onto the disk.
#
# The ed25519 host key is generated on the first build and kept in the work
# directory, so rebuilding the disk doesn't change the VM's host key.

require dropbear dropbear-bin
require dropbearkey dropbear-bin
require dbclient dropbear-bin

[ -n "${SSH_AUTHORIZED_KEYS:-}" ] || {
    echo "Set SSH_AUTHORIZED_KEYS to a public key file to log in with, e.g." >&2
    echo "  SSH_AUTHORIZED_KEYS=~/.ssh/id_ed25519.pub ./build-disk.sh dropbear" >&2
    exit 1
}
[ -f "$SSH_AUTHORIZED_KEYS" ] || { echo "No such file: $SSH_AUTHORIZED_KEYS" >&2; exit 1; }

# shellcheck source=../bash/install.sh
source "$SCRIPT_DIR/apps/bash/install.sh"

install_binary "$(command -v dropbear)"
install_binary "$(command -v dropbearkey)"
install_binary "$(command -v dbclient)"

# Debian's dropbear runs /usr/lib/sftp-server for sftp, and for scp (which
# uses the SFTP protocol); that comes from OpenSSH, so it's optional.
if [ -e /usr/lib/sftp-server ]; then
    install_binary /usr/lib/sftp-server
else
    echo "WARNING: no /usr/lib/sftp-server (openssh-sftp-server), so no sftp or scp." >&2
fi

# Clients pass their own TERM, which bash's line editing needs a terminfo
# entry for.
for term in xterm xterm-256color screen screen-256color tmux tmux-256color vt100; do
    terminfo="$(find /usr/share/terminfo /lib/terminfo -path "*/${term:0:1}/$term" -print -quit 2>/dev/null)"
    if [ -n "$terminfo" ]; then cp --parents -L "$terminfo" "$ROOTFS"; fi
done

host_key="$WORKDIR/dropbear_ed25519_host_key"
[ -f "$host_key" ] || dropbearkey -t ed25519 -f "$host_key" >/dev/null
install -D -m 600 "$host_key" "$ROOTFS/etc/dropbear/dropbear_ed25519_host_key"

# dropbear refuses a key login if root's home, ~/.ssh or authorized_keys is
# writable by anyone else, so don't leave them to the build's umask.
install -d -m 700 "$ROOTFS/root" "$ROOTFS/root/.ssh"
install -m 600 "$SSH_AUTHORIZED_KEYS" "$ROOTFS/root/.ssh/authorized_keys"

# For the pid file, and the login records dropbear writes.
install -D -m 644 /dev/null "$ROOTFS/var/run/utmp"
install -D -m 644 /dev/null "$ROOTFS/var/log/wtmp"
install -D -m 644 /dev/null "$ROOTFS/var/log/lastlog"
