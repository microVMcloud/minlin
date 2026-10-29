# Sourced by build-disk.sh: installs the host's lightpanda (a headless
# browser, one ~77MB binary needing only libc and libm), the CA certificates
# it verifies TLS with, and coreutils' env to start it with telemetry off.
#
# lightpanda isn't packaged; install it from https://lightpanda.io, e.g. into
# ~/.local/bin, or point LIGHTPANDA at the binary.
# curl -fsSL https://pkg.lightpanda.io/install.sh | bash

LIGHTPANDA="${LIGHTPANDA:-$(command -v lightpanda || true)}"
[ -x "$LIGHTPANDA" ] || {
    echo "lightpanda not found. Install it from https://lightpanda.io via 'curl -fsSL https://pkg.lightpanda.io/install.sh | bash' or set LIGHTPANDA=/path/to/lightpanda" >&2
    exit 1
}

# init.conf lines can't set environment variables, so go through env.
install_binary "$(command -v env)"
# Install at a fixed path so init.conf doesn't depend on where the host keeps it.
mkdir -p "$ROOTFS/usr/bin"
cp -L "$LIGHTPANDA" "$ROOTFS/usr/bin/lightpanda"
install_binary "$ROOTFS/usr/bin/lightpanda"
# Its TLS stack reads the hashed certificates in the directory, not the bundle.
cp -a --parents -L /etc/ssl/certs "$ROOTFS"

DISK_SIZE=256M
