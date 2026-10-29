# Lightpanda on minlin

This app runs [Lightpanda](https://lightpanda.io), a headless browser, as the
only program in a minlin microVM. It serves the Model Context Protocol (MCP)
over HTTP on port 80, so an AI agent such as Claude Code can load pages, run
their JavaScript, read them as markdown or a semantic tree, click and fill in
forms, all from inside a throwaway VM rather than on the host.

## Requirements

On the host:

- Lightpanda. It isn't packaged: install it from its site (for example into
  `~/.local/bin`). The build uses the `lightpanda` on the `PATH`, or the
  binary `LIGHTPANDA=` names. The VM gets whatever version that is; this app
  was tested with 1.1.0-nightly.11275.
- `env` (coreutils) and the CA certificates in `/etc/ssl/certs`
  (ca-certificates), plus what minlin itself needs (see the top-level
  README).
- A kernel from the current `build-linux.sh`, which enables `madvise` (see
  [Kernel support](#kernel-support)). An older `sys/bzImage` makes lightpanda
  abort at startup.

## Build and boot

    ./build-linux.sh                     # once, or after kernel/init changes
    ./build-disk.sh lightpanda
    MEM=64 HOSTFWD=8080 ./boot-qemu.sh

`HOSTFWD` switches QEMU to user-mode networking, which also gives the guest
its way out to the internet, and forwards that host port to the guest's port
80. Lightpanda's log goes to the serial console, one logfmt line per event
(navigations, scripts it runs, errors).

Under Firecracker the guest is on the bridge (`br0` by default) with its own
IP, so use `http://<guest IP>/mcp` instead (only QEMU has been tested).

## Using it

From Claude Code:

    claude mcp add --transport http minlin-browser http://localhost:8080/mcp

The server's tools then show up in Claude Code (`goto`, `markdown`, `tree`,
`click`, `fill`, `extract`, `screenshot`, `search`, ...), and the server's
instructions tell the model how to use them.

Any MCP client works. By hand with curl, `initialize` returns an
`Mcp-Session-Id` header that later requests send back:

    curl -si -X POST http://localhost:8080/mcp \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'

    curl -s -X POST http://localhost:8080/mcp \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -H 'Mcp-Session-Id: s1' \
        -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"markdown","arguments":{"url":"https://news.ycombinator.com","maxBytes":2000}}}'

Each client gets its own browsing session (its own page, cookies and
history). A session idle for 10 minutes (`--http-session-timeout 600`) is
closed, and the client's next request gets a 404, telling it to start a new
one.

## Security

The VM is the sandbox: a page that exploits the browser gets a VM with no
shell, nothing on its disk worth taking, and a reboot away from a clean
state (rebuild the disk to discard anything written to it). Still:

- The MCP endpoint has no authentication. Anyone who can reach the port can
  drive the browser, so don't expose it beyond the host (QEMU's `HOSTFWD`
  listens on all host interfaces) or a network you trust.
- The guest can reach what its network can. Under QEMU user-mode networking
  that includes the host itself at 10.0.2.2, and under Firecracker whatever
  is on the bridge. To stop pages (or a misled agent) from reaching local
  services, add `--block-private-networks` to the command in
  `rootfs/etc/init.conf`; `--block-cidrs` allows exceptions.
- Treat what the browser reads as untrusted input to the agent. The server's
  instructions say so too.

## Shutting down

lightpanda runs as `respawn`, so init restarts it if it crashes, and the VM
runs until it is killed (Ctrl-A x in QEMU). Nothing on the disk needs
keeping, so that loses nothing that matters.

## Memory

64MB is enough to load and render a large page (Wikipedia's "Linux kernel"
article) with one client. The guest starts with about 52MB free at 64MB; more
clients, or heavier JavaScript sites, need more. The default 32MB hasn't
been tried.

## What's on the disk

| Path | Purpose |
|------|---------|
| `/usr/bin/lightpanda` | the browser (Zig, with V8 and libcurl built in; links only libc and libm) |
| `/usr/bin/env` | starts lightpanda with `LIGHTPANDA_DISABLE_TELEMETRY=true`, since `init.conf` can't set environment variables |
| `/etc/ssl/certs/` | CA certificates. Lightpanda reads the individual hashed files here, not the bundle |
| `/etc/resolv.conf` | DNS via 1.1.1.1 and 8.8.8.8 |
| `/.local/share/lightpanda/` | created by lightpanda at startup (init sets `HOME=/`) |
| `/lib`, `/lib64`, ... | glibc and the dynamic loader, from the host |

The disk is 256MB (`DISK_SIZE` in `install.sh`), as the binary alone is too
much for the default 128MB with room to spare.

To serve the Chrome DevTools Protocol instead, for Puppeteer or Playwright,
replace `mcp ... --port 80` in `rootfs/etc/init.conf` with
`serve --host 0.0.0.0 --port 80 --advertise-host localhost` (untested).

## Kernel support

V8 returns memory to the kernel with `madvise` and treats a failed call as
fatal: without `CONFIG_ADVISE_SYSCALLS`, which tinyconfig leaves out,
lightpanda aborts as it starts with

    # Fatal error
    # Check failed: 0 == ret.

and init restarts it about once a second. `build-linux.sh` enables it.
Otherwise lightpanda needs only what the other apps already enable: `FUTEX`
and `EPOLL`, plus `EVENTFD` for its event loop. It also calls the
`pkey_*` (memory protection key) syscalls, but copes without them.
