# Sourced by build-disk.sh: installs the host's PostgreSQL server, creates a
# fresh database cluster for it with the host's initdb, and adds util-linux
# setpriv and coreutils chown to start it as the postgres user.
#
# Set PG_VERSION to pick a major version when the host has several in
# /usr/lib/postgresql; the newest is used otherwise.
#
# Set PG_PASSWORD to choose the password of the postgres superuser. Otherwise
# one is generated on the first build and kept in the work directory
# (linux-src/postgres_password), so rebuilding the disk keeps it. The
# database itself is created anew by every build.
#
# Set PG_SHARED_BUFFERS (default 8MB) to size postgres's buffer cache. The
# kernel has no SHMEM, so shared memory can't be swapped or reclaimed: once
# touched it stays in guest RAM. 16MB got a backend killed for want of memory
# loading pgbench -s 2 in a 48MB guest; 8MB didn't.

[ -d /usr/lib/postgresql ] || {
    echo "PostgreSQL not found. On Debian/Ubuntu: sudo apt install postgresql" >&2
    exit 1
}
require openssl
require setpriv util-linux
# initdb refuses to run as root, and so would the server it starts to set up
# the cluster.
[ "$(id -u)" != 0 ] || { echo "Build the postgres app as a regular user: initdb refuses root." >&2; exit 1; }

PG_VERSION="${PG_VERSION:-$(ls /usr/lib/postgresql | sort -n | tail -n 1)}"
pg_bin="/usr/lib/postgresql/$PG_VERSION/bin"
[ -x "$pg_bin/postgres" ] && [ -x "$pg_bin/initdb" ] || {
    echo "No PostgreSQL $PG_VERSION server in $pg_bin. On Debian/Ubuntu: sudo apt install postgresql-$PG_VERSION" >&2
    exit 1
}

# postgres finds its share and lib directories relative to its real path,
# following symlinks, so init.conf can name a path that doesn't change with
# the version.
install_binary "$pg_bin/postgres"
mkdir -p "$ROOTFS/usr/local/bin"
ln -s "$pg_bin/postgres" "$ROOTFS/usr/local/bin/postgres"
# Loaded by the first call to a PL/pgSQL function, which initdb sets up as
# the default procedural language. Other modules (contrib, JIT) aren't
# installed.
install_binary "/usr/lib/postgresql/$PG_VERSION/lib/plpgsql.so"
# Read at startup: the time zone abbreviations, and the zone the log and
# sessions use (set to UTC below, as the guest has no other zone data).
cp -a --parents "/usr/share/postgresql/$PG_VERSION/timezonesets" "$ROOTFS"
cp -a --parents -L /usr/share/zoneinfo/UTC "$ROOTFS"

install_binary "$(command -v setpriv)"
install_binary "$(command -v chown)"

password_file="$WORKDIR/postgres_password"
if [ -n "${PG_PASSWORD:-}" ]; then
    printf '%s\n' "$PG_PASSWORD" > "$password_file"
elif [ ! -f "$password_file" ]; then
    openssl rand -hex 16 > "$password_file"
fi
chmod 600 "$password_file"

# The settings below are for the guest:
#   dynamic_shared_memory_type  posix (the default) needs /dev/shm, which the
#                               kernel doesn't have
#   unix_socket_directories     /tmp is writable only by root, and clients
#                               connect over TCP
#   jit                         the JIT module (LLVM) isn't installed
#   huge_pages                  the kernel has none, so don't try
#   maintenance_work_mem        the default 64MB is more than the guest has,
#                               and building an index or vacuuming a large
#                               table gets the backend killed for want of
#                               memory
#   io_method                   sync does the I/O in each backend, instead of
#                               in three I/O worker processes
#   max_logical_replication_workers
#                               0 doesn't start the logical replication
#                               launcher
# Each process costs ~2.5MB of private memory and page tables, more than
# a guest this size can spare for ones it doesn't need.
# --no-locale: the disk has no locale data, and the C locale needs none.
log "Creating a PostgreSQL $PG_VERSION database cluster"
data="$ROOTFS/var/lib/postgresql/data"
mkdir -p "$ROOTFS/var/lib/postgresql"
"$pg_bin/initdb" -D "$data" -U postgres --pwfile="$password_file" \
    --auth-local=scram-sha-256 --auth-host=scram-sha-256 \
    --no-locale -E UTF8 --no-instructions \
    -c listen_addresses=0.0.0.0 \
    -c unix_socket_directories='' \
    -c dynamic_shared_memory_type=sysv \
    -c shared_buffers="${PG_SHARED_BUFFERS:-8MB}" \
    -c max_connections=20 \
    -c maintenance_work_mem=8MB \
    -c io_method=sync \
    -c max_logical_replication_workers=0 \
    -c jit=off \
    -c huge_pages=off \
    -c timezone=UTC \
    -c log_timezone=UTC
# initdb only lets in clients on the loopback address.
printf 'host all all 0.0.0.0/0 scram-sha-256\n' >> "$data/pg_hba.conf"
echo "postgres password (also in $password_file): $(cat "$password_file")"

DISK_SIZE=256M
