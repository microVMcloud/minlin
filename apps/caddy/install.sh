# Sourced by build-disk.sh: installs the host's caddy (a Go binary needing
# only libc), coreutils' env to point its state directories at /var/lib, and
# that directory.

require caddy

install_binary "$(command -v caddy)"
# init.conf lines can't set environment variables, so go through env.
install_binary "$(command -v env)"
mkdir -p "$ROOTFS/var/lib/caddy"
