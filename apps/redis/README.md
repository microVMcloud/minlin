# Redis on minlin

This app runs [Redis](https://redis.io) as the only program in a minlin
microVM, listening on port 6379 with a password, and keeps its data in an
append-only file on the disk.

## Requirements

On the host:

- gcc and make (`sudo apt install build-essential`), curl, tar and openssl,
  plus what minlin itself needs (see the top-level README). Redis publishes
  source but no binaries, so the build compiles it.
- Internet access for the first build of each version: GitHub, to find the
  latest release and its checksum, and download.redis.io for the source.
- A Redis client to connect. The build leaves one that runs on the host in
  `linux-src/redis/<version>/redis-cli`.

## Build and boot

    ./build-disk.sh redis
    REDISFWD=6379 ./boot-qemu.sh

Then, from the host:

    linux-src/redis/*/redis-cli -h localhost -a "$(cat linux-src/redis_password)"

- The build asks GitHub for the latest release (release candidates are
  skipped), downloads `redis-<version>.tar.gz` from download.redis.io and
  checks it against the SHA-256 in
  [redis/redis-hashes](https://github.com/redis/redis-hashes). It compiles
  only `redis-server` and `redis-cli` from `src/`, without TLS, and strips
  them. That took 23 seconds on 8 cores for 8.12.0. The top-level `make` also
  builds RediSearch, RedisJSON and the other modules, which need Rust and
  more, so these aren't included.
- Each version is kept in `linux-src/redis/<version>/`, so a rebuild doesn't
  download or compile it again. `REDIS_VERSION=8.12.0` pins a version, and a
  version that's already there builds offline.
- `REDISFWD` switches QEMU to user-mode networking and forwards that host
  port to the guest's port 6379. Pick another (`REDISFWD=16379`) if the host
  runs its own Redis. It can be combined with the other `*FWD` variables.
- The password of the default user is generated on the first build and kept
  in `linux-src/redis_password`, so rebuilding the disk keeps it. Set
  `REDIS_PASSWORD=` to choose it instead. It can't hold whitespace, quotes or
  backslashes. The build prints it.
- `REDIS_MAXMEMORY=` caps the data, 8mb by default. See [Memory](#memory).

Under Firecracker the guest is on the bridge with its own IP:

    ./boot-firecracker.sh
    linux-src/redis/*/redis-cli -h <guest IP> -a "$(cat linux-src/redis_password)"

The Firecracker setup is untested.

The settings are in `rootfs/etc/redis/redis.conf`. The build appends
`requirepass` and `maxmemory` to the disk's copy, so the password never goes
into `apps/`. The log goes to the serial console.

## Persistence

Each `build-disk.sh redis` starts with an empty database. Between builds the
data lives in `/var/lib/redis` on `sys/diskimage` and persists across boots.

`appendonly yes` with `appendfsync everysec` fsyncs each second's writes to
the disk. That makes the data survive a killed VM, which skips init's final
sync. Tested by filling the database, killing QEMU with `timeout` and
booting again: all 46,400 keys loaded. A shutdown signal to init makes it
send SIGTERM to Redis, which flushes the file before it exits. That path is
untested here.

When the file grows, Redis rewrites it in a forked child, and also on
`BGREWRITEAOF`. The fork needs little extra memory while the data doesn't
change (Redis logged 0MB copy-on-write in the tests below), but it needs
some headroom.

## Memory

`maxmemory-policy noeviction` makes writes past `REDIS_MAXMEMORY` fail with
`OOM command not allowed when used memory > 'maxmemory'`, rather than
getting Redis killed for want of memory. To use Redis as a cache, change it
to `allkeys-lru` in `rootfs/etc/redis/redis.conf`.

Measured with Redis 8.12.0 under QEMU with KVM. Each run sent 120,000 (or
400,000) `SET`s of 100-byte values through `redis-cli --pipe` until
`maxmemory` refused them, then ran `BGREWRITEAOF`:

| `REDIS_MAXMEMORY` | `MEM` | Free at boot | Result |
|---|---|---|---|
| 8mb | 32 (default) | 24,016 KiB | 46,400 keys, 12.8MB RSS, rewrite ok |
| 8mb | 28 | 19,924 KiB | full, rewrite ok |
| 32mb | 64 | 56,224 KiB | 198,385 keys, 39.3MB RSS, rewrite ok |
| 32mb | 56 | 48,036 KiB | full, rewrite ok |

An empty server uses 8.8MB RSS. Roughly, give the guest `REDIS_MAXMEMORY`
plus 20MB, and keep the default `MEM=32` for the default 8mb.

## What's on the disk

| Path | From |
|---|---|
| `/usr/bin/redis-server` | built from the release source, stripped (5.7MB) |
| `/usr/lib/x86_64-linux-gnu/libc.so.6`, `libm.so.6`, `/lib64/ld-linux-x86-64.so.2` | the host, found with `ldd` |
| `/etc/redis/redis.conf` | `rootfs/`, with the password and limit appended |
| `/var/lib/redis/` | created empty. Redis keeps `appendonlydir/` here |

The server is linked against the host's glibc, which the disk gets a copy of,
so the version built on one host runs on that host's disk images. jemalloc is
built in, as in the official builds.

## Kernel support

Nothing beyond the minimal kernel: Redis uses `EPOLL`, `FUTEX`, `fork` and
`fsync`. Its background threads (lazy free, AOF fsync) run on the one CPU.
The kernel's overcommit default is patched to "always", which Redis's
startup check wants for `fork` and would otherwise warn about.

## Log messages you can ignore

- `Increased maximum number of open files to 10032`: Redis raises its own
  limit at startup.
- `monotonic clock: x86 linux, kernel clocksource is not 'tsc'`, followed by
  `monotonic clock: POSIX clock_gettime`: the guest's clock source is
  kvm-clock, so Redis reads the time through the vDSO instead of `rdtsc`.
- `BGSAVE done, 0 keys saved` and `Creating AOF base file ... on server
  start`: the first boot sets up the empty append-only file.
