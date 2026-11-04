# Sourced by build-disk.sh: installs the host's bash, setsid (util-linux) to
# give it the console as its controlling terminal, the terminfo entry for that
# console, and busybox for the everyday commands to use from it.

require bash
require setsid util-linux
require busybox busybox-static

install_binary "$(command -v bash)"
install_binary "$(command -v setsid)"
# The prompt. Copied here, not just left in rootfs/, so that apps which
# source this file for their shell (apps/sshd) get it too.
cp "$SCRIPT_DIR/apps/bash/rootfs/etc/bash.bashrc" "$SCRIPT_DIR/apps/bash/rootfs/etc/profile" "$ROOTFS/etc/"

# The everyday commands: busybox, with a link next to it for each applet it
# was built with. Commands already on the disk (bash, setsid) keep their
# real versions. Debian/Ubuntu's busybox-static needs no shared libraries.
busybox="$(command -v busybox)"
install_binary "$busybox"
for applet in $("$busybox" --list); do
    link="$ROOTFS$(dirname "$busybox")/$applet"
    [ -e "$link" ] || ln -s busybox "$link"
done
# system() and popen() run /bin/sh, whatever PATH says. Without it they fail
# with status 127. Here /bin is only missing if the host's busybox is in /usr/bin,
# where the sh applet's link just went.
[ -e "$ROOTFS/bin" ] || ln -s usr/bin "$ROOTFS/bin"

# The kernel starts init with TERM=linux, which init passes on to bash.
# readline needs that terminal's description for line editing.
terminfo="$(find /usr/share/terminfo /lib/terminfo -path '*/l/linux' -print -quit 2>/dev/null)"
[ -n "$terminfo" ] || { echo "No terminfo entry for 'linux' (ncurses-base)" >&2; exit 1; }
cp --parents -L "$terminfo" "$ROOTFS"
