# Sourced by build-disk.sh: builds redis-server from the latest Redis release
# and installs it with its settings, a password and a memory limit.
#
# Redis publishes source but no binaries, so the build asks GitHub for the
# latest release, downloads that release's source from download.redis.io,
# checks it against the SHA-256 in github.com/redis/redis-hashes and compiles
# it (about 25 seconds on 8 cores). Only the core server is built, without TLS
# or the modules (RediSearch, RedisJSON, ...), which need Rust and more. Set
# REDIS_VERSION (e.g. 8.12.0) to pin a version instead. Each version's
# redis-server and redis-cli are kept in $WORKDIR/redis/<version>/, so a
# rebuild doesn't download or compile it again, and a pinned version that's
# there builds offline. That redis-cli runs on the host, to reach the guest.
#
# Set REDIS_PASSWORD to choose the password of the default user. Otherwise one
# is generated on the first build and kept in the work directory
# (linux-src/redis_password), so rebuilding the disk keeps it. The data
# itself starts empty with every build.
#
# Set REDIS_MAXMEMORY (default 8mb) to cap the data Redis holds. Writes past
# it fail with an OOM error. See apps/redis/README.md for what fits in what
# MEM.

require curl
require sha256sum coreutils
require tar
require make
require gcc
require openssl

redis_version="${REDIS_VERSION:-}"
if [ -z "$redis_version" ]; then
    # GitHub redirects .../releases/latest to .../releases/tag/<version>,
    # skipping release candidates. This avoids the API, which limits
    # unauthenticated clients to 60 requests an hour.
    latest="$(curl -fsS -m 30 -o /dev/null -w '%{redirect_url}' \
        https://github.com/redis/redis/releases/latest)" || {
        echo "Couldn't reach GitHub to find the latest Redis." >&2
        echo "Set REDIS_VERSION to a version kept in $WORKDIR/redis to build offline." >&2
        exit 1
    }
    redis_version="${latest##*/}"
fi
redis_version="${redis_version#v}"
# It becomes part of a URL, a path and a grep pattern.
[[ "$redis_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?$ ]] || {
    echo "Not a Redis version: '$redis_version'" >&2
    exit 1
}

redis_dir="$WORKDIR/redis/$redis_version"
if [ ! -x "$redis_dir/redis-server" ] || [ ! -x "$redis_dir/redis-cli" ]; then
    log "Downloading Redis $redis_version"
    tarball="redis-$redis_version.tar.gz"
    # Left behind by a build that failed partway.
    rm -rf "$WORKDIR"/redis_build.*
    dl="$(mktemp -d "$WORKDIR/redis_build.XXXXXX")"
    curl -fsSL -m 300 -o "$dl/$tarball" "https://download.redis.io/releases/$tarball"
    # Lines read "hash <file> sha256 <hex> <url>". A tarball that doesn't
    # match, or has no line, fails the build here.
    curl -fsSL -m 30 -o "$dl/hashes" \
        https://raw.githubusercontent.com/redis/redis-hashes/master/README
    awk -v f="$tarball" '$1 == "hash" && $2 == f && $3 == "sha256" { print $4 "  " f }' \
        "$dl/hashes" >"$dl/sha256sums"
    [ -s "$dl/sha256sums" ] || { echo "No SHA-256 for $tarball in redis-hashes." >&2; exit 1; }
    (cd "$dl" && sha256sum --check --quiet --strict sha256sums)
    tar -xzf "$dl/$tarball" -C "$dl"

    log "Compiling Redis $redis_version"
    # Building in src/ gives the core server only. The top-level Makefile
    # also tries to build the modules, and fails without their toolchains.
    make -C "$dl/redis-$redis_version/src" -j"$(nproc)" BUILD_TLS=no \
        redis-server redis-cli >"$dl/build.log" 2>&1 || {
        tail -n 30 "$dl/build.log" >&2
        echo "Redis build failed; the full log is $dl/build.log" >&2
        exit 1
    }
    mkdir -p "$redis_dir"
    # Unstripped, the server is 26MB, most of it debug symbols.
    strip -o "$redis_dir/redis-server" "$dl/redis-$redis_version/src/redis-server"
    strip -o "$redis_dir/redis-cli" "$dl/redis-$redis_version/src/redis-cli"
    rm -rf "$dl"
fi
log "Using Redis $redis_version"

mkdir -p "$ROOTFS/usr/bin"
cp "$redis_dir/redis-server" "$ROOTFS/usr/bin/redis-server"
install_libs "$ROOTFS/usr/bin/redis-server"
mkdir -p "$ROOTFS/var/lib/redis"

password_file="$WORKDIR/redis_password"
if [ -n "${REDIS_PASSWORD:-}" ]; then
    printf '%s\n' "$REDIS_PASSWORD" >"$password_file"
elif [ ! -f "$password_file" ]; then
    openssl rand -hex 16 >"$password_file"
fi
chmod 600 "$password_file"
redis_password="$(cat "$password_file")"
# It goes into redis.conf in double quotes.
[[ "$redis_password" =~ ^[^[:space:]\"\\]+$ ]] || {
    echo "REDIS_PASSWORD can't hold spaces, quotes or backslashes." >&2
    exit 1
}

redis_maxmemory="${REDIS_MAXMEMORY:-8mb}"
[[ "$redis_maxmemory" =~ ^[0-9]+([kKmMgG][bB]?)?$ ]] || {
    echo "Not a Redis memory size: '$redis_maxmemory' (e.g. 8mb)" >&2
    exit 1
}

{
    echo
    echo "# Added by apps/redis/install.sh."
    echo "requirepass \"$redis_password\""
    echo "maxmemory $redis_maxmemory"
} >>"$ROOTFS/etc/redis/redis.conf"
echo "Redis password (also in $password_file): $redis_password"
echo "Host client: $redis_dir/redis-cli"
