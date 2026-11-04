#!/usr/bin/env bash
#
# Build the ext4 diskimage (sys/diskimage) that init mounts as / for one app.
#
#   ./build-disk.sh <app> [workdir]
#
# An app lives in apps/<app>/:
#   rootfs/     copied onto the disk as-is. It should include etc/init.conf,
#               which tells init what to start.
#   install.sh  optional; sourced after rootfs/ is copied. It can call
#               install_binary to pull host programs (and the shared
#               libraries they need) onto the disk, copy anything else into
#               $ROOTFS, and set DISK_SIZE if 128M is not enough.
#
# The kernel from build-linux.sh does not depend on the app, so switching
# apps only needs this script re-run.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <app> [workdir]" >&2
    echo "Apps: $(ls "$SCRIPT_DIR/apps" | tr '\n' ' ')" >&2
    exit 1
fi

APP="$1"
APP_DIR="$SCRIPT_DIR/apps/$APP"
WORKDIR="${2:-$PWD/linux-src}"
ROOTFS="$WORKDIR/rootfs"
SYS_DIR="$SCRIPT_DIR/sys"
DISK_SIZE=128M

log() { printf '\n>>> %s\n' "$*"; }

# Fail with an install hint unless the given host command exists.
require() {
    local cmd="$1" pkg="${2:-$1}"
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "$cmd not found. On Debian/Ubuntu: sudo apt install $pkg" >&2
        exit 1
    }
}

# Copy every shared library a host binary needs (and the dynamic loader) into
# the rootfs, as reported by ldd. A static binary needs nothing.
install_libs() {
    local bin="$1" deps
    # "|| true": ldd fails on a static binary.
    deps="$(ldd "$bin" 2>/dev/null || true)"
    # These lines hold no path to copy, so the first anyone would hear of the
    # missing library is the program failing to start in the guest.
    if grep -q '=> not found' <<<"$deps"; then
        echo "Missing libraries for $bin:" >&2
        grep '=> not found' <<<"$deps" >&2
        exit 1
    fi
    # "|| true": a file with no dependencies gives grep nothing to match.
    { grep -o '/[^ ]*' <<<"$deps" || true; } | while read -r lib; do
        [ -e "$ROOTFS$lib" ] || cp --parents -L "$lib" "$ROOTFS"
    done
}

# Copy a host binary into the rootfs at the same path, with its libraries.
install_binary() {
    local bin="$1"
    cp --parents -L "$bin" "$ROOTFS"
    install_libs "$bin"
}

# Where a path on the disk really is on the host, following a symlink at its
# end. An absolute link target means the disk's /, not the host's.
rootfs_path() {
    local path="$1" target hops=0
    while [ -L "$ROOTFS$path" ] && [ "$hops" -lt 16 ]; do
        target="$(readlink "$ROOTFS$path")"
        case "$target" in
            /*) path="$target" ;;
            *) path="$(dirname "$path")/$target" ;;
        esac
        hops=$((hops + 1))
    done
    printf '%s\n' "$ROOTFS$path"
}

# Fail the build for init.conf entries that init could only fail to start, which
# would otherwise show up as a message on the console at boot. Reads each line
# the way init does. Only the program init executes is checked: it can't tell
# which later arguments (such as the program after env) are meant to be run.
check_init_conf() {
    local conf="$ROOTFS/etc/init.conf" action path rest file interp errors=0 lineno=0
    bad() { echo "etc/init.conf:$lineno: $*" >&2; errors=$((errors + 1)); }
    while read -r action path rest || [ -n "$action" ]; do
        lineno=$((lineno + 1))
        case "$action" in
            ''|'#'*) continue ;;
            wait|once|respawn) ;;
            *) bad "unknown action '$action'"; continue ;;
        esac
        case "$path" in
            '') bad "no command given"; continue ;;
            /*) ;;
            *) bad "$path: path must be absolute, init doesn't search PATH"; continue ;;
        esac
        file="$(rootfs_path "$path")"
        if [ ! -f "$file" ]; then
            bad "$path: not on the disk"
        elif [ ! -x "$file" ]; then
            bad "$path: not executable"
        elif [ "$(head -c 2 "$file")" = '#!' ]; then
            bad "$path: is a script and the kernel can't run those, name its interpreter"
        elif [ "$(head -c 4 "$file")" != $'\x7fELF' ]; then
            bad "$path: not an ELF binary"
        else
            interp="$(readelf -l "$file" | sed -n 's/.*program interpreter: \(.*\)\]$/\1/p')"
            if [ -n "$interp" ] && [ ! -f "$(rootfs_path "$interp")" ]; then
                bad "$path: its dynamic loader $interp is not on the disk"
            fi
        fi
    done <"$conf"
    [ "$errors" -eq 0 ] || exit 1
}

[ -d "$APP_DIR" ] || { echo "No such app: $APP_DIR" >&2; exit 1; }
require ldd libc-bin
require mkfs.ext4 e2fsprogs
require readelf binutils

log "Assembling root filesystem for $APP in $ROOTFS"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
[ -d "$APP_DIR/rootfs" ] && cp -a "$APP_DIR/rootfs/." "$ROOTFS/"
if [ -f "$APP_DIR/install.sh" ]; then
    # shellcheck source=/dev/null
    source "$APP_DIR/install.sh"
fi
if [ -f "$ROOTFS/etc/init.conf" ]; then
    check_init_conf
else
    echo "WARNING: $APP has no etc/init.conf, init will have nothing to run." >&2
fi

log "Creating $DISK_SIZE ext4 diskimage from $ROOTFS"
mkdir -p "$SYS_DIR"
# Build beside the real image and move it into place at the end, so a failed
# mkfs leaves the last good image rather than a corrupt one.
new_image="$SYS_DIR/diskimage.new.$$"
tarball="$WORKDIR/rootfs.tar"
trap 'rm -f "$new_image" "$tarball"' EXIT
# Both can hold an app's keys and tokens, so only this user may read them. The
# umask stays out of the assembly above, where it would set the modes of
# directories on the disk and lock out the guest's non-root users.
umask 077
# mke2fs -d with a directory keeps each file's owner (whoever ran the build),
# so go through a tarball that records everything as root's. sshd, for one,
# refuses a privsep directory or keys that root doesn't own.
tar -C "$ROOTFS" --owner=0 --group=0 --numeric-owner -cf "$tarball" .
mkfs.ext4 -q -d "$tarball" "$new_image" "$DISK_SIZE"
mv -f "$new_image" "$SYS_DIR/diskimage"
