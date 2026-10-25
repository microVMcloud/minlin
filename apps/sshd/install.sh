# Sourced by build-disk.sh: installs the host's OpenSSH server (and client),
# along with bash and the everyday commands from apps/bash as the login shell.
#
# Set SSH_AUTHORIZED_KEYS to a file of public keys (an authorized_keys file
# or a single .pub) allowed to log in as root; it is copied onto the disk.
#
# The ed25519 host key is generated on the first build and kept in the work
# directory, so rebuilding the disk doesn't change the VM's host key.

require sshd openssh-server
require ssh openssh-client
require ssh-keygen openssh-client

[ -n "${SSH_AUTHORIZED_KEYS:-}" ] || {
    echo "Set SSH_AUTHORIZED_KEYS to a public key file to log in with, e.g." >&2
    echo "  SSH_AUTHORIZED_KEYS=~/.ssh/id_ed25519.pub ./build-disk.sh sshd" >&2
    exit 1
}
if [ ! -f "$SSH_AUTHORIZED_KEYS" ]; then
    echo "No such file: $SSH_AUTHORIZED_KEYS" >&2
    # A .pub whose private key is there can be regenerated from it;
    # otherwise make a new key pair.
    private_key="${SSH_AUTHORIZED_KEYS%.pub}"
    if [ "$private_key" != "$SSH_AUTHORIZED_KEYS" ] && [ -f "$private_key" ]; then
        echo "Recreate it from the private key with:" >&2
        echo "  ssh-keygen -y -f $private_key > $SSH_AUTHORIZED_KEYS" >&2
    else
        echo "Create a key pair with:" >&2
        echo "  ssh-keygen -t ed25519" >&2
        echo "then build with SSH_AUTHORIZED_KEYS=~/.ssh/id_ed25519.pub" >&2
    fi
    exit 1
fi

# shellcheck source=../bash/install.sh
source "$SCRIPT_DIR/apps/bash/install.sh"

# sshd re-executes sshd-session for each connection, which runs the
# unauthenticated side in sshd-auth; scp and sftp use sftp-server.
install_binary "$(command -v sshd)"
for prog in sshd-session sshd-auth sftp-server; do
    install_binary "/usr/lib/openssh/$prog"
done
install_binary "$(command -v ssh)"
install_binary "$(command -v ssh-keygen)"

# Clients pass their own TERM, which bash's line editing needs a terminfo
# entry for.
for term in xterm xterm-256color screen screen-256color tmux tmux-256color vt100; do
    terminfo="$(find /usr/share/terminfo /lib/terminfo -path "*/${term:0:1}/$term" -print -quit 2>/dev/null)"
    if [ -n "$terminfo" ]; then cp --parents -L "$terminfo" "$ROOTFS"; fi
done

host_key="$WORKDIR/ssh_host_ed25519_key"
[ -f "$host_key" ] || ssh-keygen -q -t ed25519 -N '' -C "root@minlin" -f "$host_key"
install -m 600 "$host_key" "$ROOTFS/etc/ssh/ssh_host_ed25519_key"
install -m 644 "$host_key.pub" "$ROOTFS/etc/ssh/ssh_host_ed25519_key.pub"

install -d -m 700 "$ROOTFS/root/.ssh"
install -m 600 "$SSH_AUTHORIZED_KEYS" "$ROOTFS/root/.ssh/authorized_keys"

# The unprivileged pre-auth process is chrooted here; it must be root's and
# not writable by anyone else.
install -d -m 755 "$ROOTFS/run/sshd"

# sshd records each login in lastlog and utmp, and logs an error for each
# one that's missing.
install -D -m 644 /dev/null "$ROOTFS/var/log/lastlog"
install -D -m 644 /dev/null "$ROOTFS/var/run/utmp"
