# Sourced by build-disk.sh: installs Caddy's official static linux_amd64
# build from its GitHub releases, coreutils' env to point its state
# directories at /var/lib, and that directory.
#
# The build asks GitHub for the latest release and checks the download
# against the release's SHA-512 checksums. Set CADDY_VERSION (e.g. 2.11.9) to
# pin a version instead. Each version is kept in $WORKDIR/caddy/<version>/,
# so rebuilding doesn't download it again, and a pinned version that's there
# builds offline.

require curl
require sha512sum coreutils
require tar

caddy_version="${CADDY_VERSION:-}"
if [ -z "$caddy_version" ]; then
    # GitHub redirects .../releases/latest to .../releases/tag/v<version>.
    # This avoids the API, which limits unauthenticated clients to 60
    # requests an hour.
    latest="$(curl -fsS -m 30 -o /dev/null -w '%{redirect_url}' \
        https://github.com/caddyserver/caddy/releases/latest)" || {
        echo "Couldn't reach GitHub to find the latest Caddy." >&2
        echo "Set CADDY_VERSION to a version kept in $WORKDIR/caddy to build offline." >&2
        exit 1
    }
    caddy_version="${latest##*/v}"
fi
caddy_version="${caddy_version#v}"
# It becomes part of a URL and a path.
[[ "$caddy_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || {
    echo "Not a Caddy version: '$caddy_version'" >&2
    exit 1
}

caddy_dir="$WORKDIR/caddy/$caddy_version"
if [ ! -x "$caddy_dir/caddy" ]; then
    log "Downloading Caddy $caddy_version from GitHub"
    url="https://github.com/caddyserver/caddy/releases/download/v$caddy_version"
    tarball="caddy_${caddy_version}_linux_amd64.tar.gz"
    # Left behind by a build that failed partway.
    rm -rf "$WORKDIR"/caddy_download.*
    dl="$(mktemp -d "$WORKDIR/caddy_download.XXXXXX")"
    curl -fsSL -m 300 -o "$dl/$tarball" "$url/$tarball"
    curl -fsSL -m 30 -o "$dl/checksums.txt" "$url/caddy_${caddy_version}_checksums.txt"
    # A tarball that doesn't match, or has no line, fails the build here.
    grep " $tarball\$" "$dl/checksums.txt" | (cd "$dl" && sha512sum --check --quiet --strict)
    # Only the binary: the tarball also holds the licence and README.
    tar -xzf "$dl/$tarball" -C "$dl" caddy
    mkdir -p "$caddy_dir"
    mv "$dl/caddy" "$caddy_dir/caddy"
    rm -rf "$dl"
fi
log "Using Caddy $caddy_version"

mkdir -p "$ROOTFS/usr/bin"
cp "$caddy_dir/caddy" "$ROOTFS/usr/bin/caddy"
# The official build is static, so this finds nothing, unless that changes.
install_libs "$ROOTFS/usr/bin/caddy"
# init.conf lines can't set environment variables, so go through env.
install_binary "$(command -v env)"
mkdir -p "$ROOTFS/var/lib/caddy"
