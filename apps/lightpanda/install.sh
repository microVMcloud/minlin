# Sourced by build-disk.sh: installs the host's lightpanda (a headless
# browser, one ~77MB binary needing only libc and libm), the CA certificates
# it verifies TLS with, coreutils' env to start it with telemetry off, and
# lighttpd as the reverse proxy in front of it that checks the bearer token.
#
# lightpanda isn't packaged; install it from https://lightpanda.io, e.g. into
# ~/.local/bin, or point LIGHTPANDA at the binary.
# curl -fsSL https://pkg.lightpanda.io/install.sh | bash
#
# Set MCP_TOKEN to choose the bearer token clients must send. Otherwise one
# is generated on the first build and kept in the work directory
# (linux-src/lightpanda_mcp_token), so rebuilding the disk keeps it.

LIGHTPANDA="${LIGHTPANDA:-$(command -v lightpanda || true)}"
[ -x "$LIGHTPANDA" ] || {
    echo "lightpanda not found. Install it from https://lightpanda.io via 'curl -fsSL https://pkg.lightpanda.io/install.sh | bash' or set LIGHTPANDA=/path/to/lightpanda" >&2
    exit 1
}
require lighttpd
require openssl

# init.conf lines can't set environment variables, so go through env.
install_binary "$(command -v env)"
# Install at a fixed path so init.conf doesn't depend on where the host keeps
# it, then the libraries the host's copy needs.
mkdir -p "$ROOTFS/usr/bin"
cp -L "$LIGHTPANDA" "$ROOTFS/usr/bin/lightpanda"
ldd "$LIGHTPANDA" | { grep -o '/[^ ]*' || true; } | while read -r lib; do
    install_binary "$lib"
done
# Its TLS stack reads the hashed certificates in the directory, not the bundle.
cp -a --parents -L /etc/ssl/certs "$ROOTFS"

# mod_access is built into lighttpd; mod_h2 is loaded by default.
install_binary "$(command -v lighttpd)"
moddir="$(dirname "$(find /usr/lib -name mod_h2.so -path '*lighttpd*' -print -quit)")"
for mod in h2 proxy; do
    install_binary "$moddir/mod_$mod.so"
done
mkdir -p "$ROOTFS/var/empty"

token_file="$WORKDIR/lightpanda_mcp_token"
if [ -n "${MCP_TOKEN:-}" ]; then
    printf '%s\n' "$MCP_TOKEN" > "$token_file"
elif [ ! -f "$token_file" ]; then
    openssl rand -hex 32 > "$token_file"
fi
chmod 600 "$token_file"
token="$(cat "$token_file")"
# It goes into a quoted string in lighttpd's config.
case "$token" in
    *[!A-Za-z0-9._~+/=-]*) echo "MCP_TOKEN may only use A-Z a-z 0-9 . _ ~ + / = -" >&2; exit 1 ;;
esac
(umask 077; printf 'var.mcp_token = "%s"\n' "$token" > "$ROOTFS/etc/lighttpd/token.conf")
echo "MCP bearer token (also in $token_file): $token"

DISK_SIZE=256M
