# PostgreSQL on minlin

This app runs the host's PostgreSQL server as the only program in a minlin
microVM, listening on port 5432 with a fresh database cluster created at
build time. Clients log in over TCP as `postgres` with a password.

## Requirements

On the host:

- The PostgreSQL server (`sudo apt install postgresql`). The VM gets the
  host's version, the newest in `/usr/lib/postgresql` unless `PG_VERSION=`
  names another. Tested with Ubuntu's PostgreSQL 18.6.
- util-linux (`setpriv`), coreutils (`chown`) and openssl, plus what minlin
  itself needs (see the top-level README).
- A kernel built by the current `build-linux.sh`, which enables `SYSVIPC`
  and `SIGNALFD` (see [Kernel support](#kernel-support)).
- `psql` (`postgresql-client`) or any other client, to connect.

Build as a regular user: the cluster is created with the host's `initdb`,
which refuses to run as root.

## Build and boot

    ./build-linux.sh                     # once, or after kernel/init changes
    ./build-disk.sh postgres
    MEM=48 PGFWD=5432 ./boot-qemu.sh

Then, from the host:

    PGPASSWORD=$(cat linux-src/postgres_password) psql -h localhost -U postgres

- `PGFWD` switches QEMU to user-mode networking and forwards that host port
  to the guest's port 5432. Pick another host port (`PGFWD=15432`) if the
  host runs its own PostgreSQL. It can be combined with `HOSTFWD` and
  `SSHFWD`.
- The password of the `postgres` superuser is generated on the first build
  and kept in `linux-src/postgres_password`, so rebuilding the disk keeps it.
  Set `PG_PASSWORD=` to choose it instead. The build prints it.
- `PG_SHARED_BUFFERS=` sets `shared_buffers`, 8MB by default. See
  [Memory](#memory) before raising it.

Under Firecracker the guest is on the bridge (`br0` by default) with its own
IP, so connect to that directly:

    MEM=48 ./boot-firecracker.sh
    psql -h <guest IP> -U postgres

Every build runs `initdb` again, so `build-disk.sh postgres` replaces the
database with an empty one. Between builds the database lives on
`sys/diskimage` and persists across boots.

The server log goes to the serial console.

## Shutting down

postgres runs as `once`, so init ends the VM when the postmaster exits. A
shutdown signal to init (Firecracker's `SendCtrlAltDel`) makes it send
SIGTERM to every process; postgres takes that as a smart shutdown and writes
a checkpoint before it exits. That path is untested.

QEMU here has no way to send the guest a shutdown signal, so the VM is
stopped by killing it (Ctrl-A x). postgres flushes its write-ahead log to the
disk at each commit, so committed transactions survive: after inserting
10,000 rows and killing QEMU, the next boot replayed the log ("automatic
recovery in progress") and all the rows were there.

## Memory

Give it `MEM=48`. Measured under QEMU (`boot-qemu.sh`, KVM) with the defaults
above, running `pgbench -i -s 2` (200,000 rows, then an index build and a
vacuum) followed by `pgbench -c 4 -T 10`:

| MEM | Result |
|-----|--------|
| 64 | works, ~780 tps |
| 48 | works, 740–880 tps (two runs) |
| 40 | a backend is killed for want of memory during the load; with `-s 1` it finishes but crawls (0.4 tps, 10s average latency) |
| 32 | a backend is killed during the load; with a 10,000-row table, four concurrent `SELECT`s were enough |

When the kernel kills a backend, postgres restarts all of them and recovers,
so clients see `the database system is in recovery mode` and dropped
connections, not a crash of the VM.

Idle, with one client connected, `/proc/meminfo` (read with `pg_read_file`)
shows 23.6MB available at `MEM=48` and 39.4MB at `MEM=64`.

The settings in `install.sh` are chosen for this:

- `shared_buffers` is 8MB. The kernel has no `SHMEM`, so shared memory is
  backed by ramfs and can't be reclaimed: once used, it stays in RAM. With
  16MB, the 48MB guest failed the pgbench load.
- `maintenance_work_mem` is 8MB instead of 64MB, which is more than the guest
  has, for index builds and vacuum.
- `io_method=sync` and `max_logical_replication_workers=0` drop the three I/O
  workers and the logical replication launcher. Each postgres process costs
  about 2.5MB of private memory and page tables.
- `max_connections` is 20. Each connection is a process of its own.

## What's on the disk

| Path | Purpose |
|------|---------|
| `/usr/lib/postgresql/<version>/bin/postgres` | the server (12MB), and the 58MB of shared libraries `ldd` lists for it, 33MB of which is ICU's data library |
| `/usr/local/bin/postgres` | a symlink to it, so `init.conf` doesn't name the version. postgres finds its other directories from its real path |
| `/usr/lib/postgresql/<version>/lib/plpgsql.so` | PL/pgSQL, loaded by the first call to a PL/pgSQL function. No other modules (contrib, JIT) are installed |
| `/usr/share/postgresql/<version>/timezonesets/` | time zone abbreviations, read at startup |
| `/usr/share/zoneinfo/UTC` | the only time zone on the disk; `timezone` and `log_timezone` are UTC |
| `/var/lib/postgresql/data` | the cluster, made by the host's `initdb` with `--no-locale -E UTF8` (the disk has no locale data) |
| `/usr/bin/chown`, `/usr/bin/setpriv` | hand the data directory to the `postgres` user and start the server as that user |
| `/etc/passwd`, `/etc/group` | the `postgres` user and group (uid and gid 100) |

The disk is 256MB; the files come to 120MB, 39MB of it the empty cluster.

The build makes every file on the disk root's, and postgres refuses both to
run as root and to use a data directory it doesn't own. So `init.conf` first
runs `chown -R postgres:postgres /var/lib/postgresql`, then starts postgres
through `setpriv`.

Clients are let in from any address with SCRAM password authentication
(`host all all 0.0.0.0/0 scram-sha-256` in `pg_hba.conf`). There is no Unix
socket: `/tmp` is writable only by root.

## Kernel support

PostgreSQL needs two options the minimal kernel didn't have:

| Option | Why |
|--------|-----|
| `SYSVIPC` | postgres always creates a small System V shared memory segment (`shmget`), whose attach count tells a new server whether processes of an old one are still running. It also holds the dynamic shared memory (`dynamic_shared_memory_type=sysv`), as the default `posix` type needs `/dev/shm` |
| `SIGNALFD` | postgres processes wait for signals on a signalfd. Without it the server exits at once with `FATAL: signalfd() failed` |

Together they cost 28 KiB of free memory at boot (`mem:` in the boot banner
at `MEM=64`, three boots each: 56,268 KiB before, 56,236–56,240 after), and
12 KiB of bzImage.

The main shared memory is anonymous `mmap`, and postgres's semaphores are
POSIX semaphores in that memory, built on `FUTEX`.

## Log messages you can ignore

After the VM was killed:

    LOG:  database system was not properly shut down; automatic recovery in progress

postgres replays its write-ahead log, which takes a fraction of a second.
