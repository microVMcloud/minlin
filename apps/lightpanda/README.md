# Lightpanda on minlin

This app runs [Lightpanda](https://lightpanda.io), a headless browser, in a
minlin microVM. It serves the Model Context Protocol (MCP) over HTTP on port
80, so an AI agent such as Claude Code can load pages, run their JavaScript,
read them as markdown or a semantic tree, click and fill in forms, all from
inside a throwaway VM rather than on the host. Clients need a bearer token,
so the VM can sit behind a public proxy such as microVM Cloud's.

## Requirements

On the host:

- Lightpanda. It isn't packaged: install it from its site (for example into
  `~/.local/bin`). The build uses the `lightpanda` on the `PATH`, or the
  binary `LIGHTPANDA=` names. The VM gets whatever version that is; this app
  was tested with 1.1.0-nightly.11275.
- lighttpd (with its `mod_proxy`), busybox (busybox-static), `openssl` to
  generate the token, `env` (coreutils) and the CA certificates in
  `/etc/ssl/certs` (ca-certificates), plus what minlin itself needs (see the
  top-level README).
- A kernel from the current `build-linux.sh`, which enables `madvise` (see
  [Kernel support](#kernel-support)). An older `sys/bzImage` makes lightpanda
  abort at startup.

## Build and boot

    ./build-linux.sh                     # once, or after kernel/init changes
    ./build-disk.sh lightpanda           # prints the bearer token
    MEM=128 HOSTFWD=8080 ./boot-qemu.sh

`HOSTFWD` switches QEMU to user-mode networking, which also gives the guest
its way out to the internet, and forwards that host port to the guest's port
80. Lightpanda's log goes to the serial console, one logfmt line per event
(navigations, scripts it runs, errors), along with lighttpd's errors.

Under Firecracker the guest is on the bridge (`br0` by default) with its own
IP, so use `http://<guest IP>/mcp` instead (untested). To run it on
microVM Cloud, see [Deploying to microVM Cloud](#deploying-to-microvm-cloud).

## The token

The build generates a random token on its first run and keeps it in the work
directory as `linux-src/lightpanda_mcp_token`, so rebuilding the disk keeps
it. To choose one instead (letters, digits and `. _ ~ + / = -`):

    MCP_TOKEN=... ./build-disk.sh lightpanda

which also replaces the kept one. Delete the file to have the next build
generate a new one. Requests without `Authorization: Bearer <token>` get 403
from lighttpd and never reach lightpanda.

## Using it

From Claude Code:

    claude mcp add --transport http minlin-browser http://localhost:8080/mcp \
        --header "Authorization: Bearer $(cat linux-src/lightpanda_mcp_token)"

or, for a VM on microVM Cloud, its `https://...microvmcloud.online/mcp` URL.
The server's tools then show up in Claude Code (`goto`, `markdown`, `tree`,
`click`, `fill`, `extract`, `screenshot`, `search`, ...), and the server's
instructions tell the model how to use them.

Any MCP client works. By hand with curl, `initialize` returns an
`Mcp-Session-Id` header that later requests send back:

    TOKEN=$(cat linux-src/lightpanda_mcp_token)
    curl -si -X POST http://localhost:8080/mcp \
        -H "Authorization: Bearer $TOKEN" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'

    curl -s -X POST http://localhost:8080/mcp \
        -H "Authorization: Bearer $TOKEN" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -H 'Mcp-Session-Id: s1' \
        -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"markdown","arguments":{"url":"https://news.ycombinator.com","maxBytes":2000}}}'

Each client gets its own browsing session (its own page, cookies and
history). A session idle for 10 minutes (`--http-session-timeout 600`) is
closed, and the client's next request gets a 404, telling it to start a new
one.

## Deploying to microVM Cloud

microVM Cloud runs the VM behind its own nginx, which serves HTTPS on a
`https://<name>.microvmcloud.online/` URL and passes requests to the guest's
port 80 with that name as the `Host`. Its kernel already has what lightpanda
needs, so only the disk is uploaded.

1. Build the disk. The first build generates the token; later builds keep
   it (see [The token](#the-token)):

       ./build-disk.sh lightpanda

2. Upload `sys/diskimage` to a new instance and give it 128MiB (see
   [Memory](#memory)). Note its URL.

3. Check it from the host before connecting a client. Without the token,
   lighttpd should answer 403:

       URL=https://<name>.microvmcloud.online/mcp
       TOKEN=$(cat linux-src/lightpanda_mcp_token)
       curl -s -o /dev/null -w '%{http_code}\n' -X POST "$URL" -d '{}'

   and with it, `initialize` should return 200, an `mcp-session-id` header
   and `"serverInfo":{"name":"lightpanda",...}`:

       curl -si -X POST "$URL" \
           -H "Authorization: Bearer $TOKEN" \
           -H 'Content-Type: application/json' \
           -H 'Accept: application/json, text/event-stream' \
           -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'

4. Add it to Claude Code, which stores the server in your local config for
   the current project:

       claude mcp add --transport http minlin-browser "$URL" \
           --header "Authorization: Bearer $TOKEN"
       claude mcp list                  # minlin-browser: ... ✔ Connected

5. Claude Code loads MCP servers when a session starts, so restart it
   (`claude --continue` keeps the conversation) or reconnect the server from
   `/mcp`. Until then a running session doesn't have the tools.

6. Try a real page, heavy enough to show whether the VM has enough memory,
   for example by asking Claude to read
   `https://github.com/lightpanda-io/browser/releases` with the
   `minlin-browser` tools. At 128MiB that takes a few seconds.

To change the token, delete `linux-src/lightpanda_mcp_token` (or set
`MCP_TOKEN=`), rebuild and upload the disk, then `claude mcp remove
minlin-browser` and add it again with the new token.

### Troubleshooting

| Symptom | Cause |
|---------|-------|
| 403 with an HTML "403 Forbidden" page | lighttpd: the `Authorization` header is missing or the token is wrong. Compare it with `linux-src/lightpanda_mcp_token` from the build that made the uploaded disk |
| 403 `Host not allowed, connect to the MCP endpoint by IP address or localhost` | lightpanda: the request reached it without going through lighttpd, as with a disk from before lighttpd was added. Rebuild and upload the disk |
| 503 from lighttpd | lightpanda isn't listening on 127.0.0.1:9222. On the console: `AddressNotAvailable` means `lo` didn't come up (check the busybox `wait` line in `init.conf`); `Check failed: 0 == ret.` means the kernel lacks `madvise` (see [Kernel support](#kernel-support)) |
| 504 from nginx, or 500 from lighttpd, on heavy pages only | too little memory: the console shows `page allocation failure ... GFP_ATOMIC` and pages crawl. Give the VM 128MiB or more |
| `claude mcp list` says connected, but Claude has no `minlin-browser` tools | the session started before the server was added. Restart Claude Code or reconnect from `/mcp` |
| 404 after the client has been idle | its session timed out after 10 minutes; MCP clients start a new one |
| A site returns a challenge page (DuckDuckGo's "Select all squares containing a duck") | the site blocks automated browsers. Nothing is wrong with the VM; use another site or the `search` tool |

## How requests get to lightpanda

lightpanda's MCP server only answers requests whose `Host` is an IP address
(or `localhost:<port>`), against DNS rebinding, and unlike `lightpanda serve`
it has no option to allow another name. Behind a proxy that passes on the
public name, it refuses every request with "Host not allowed". So:

    client ──> :80 lighttpd ──> 127.0.0.1:9222 lightpanda
               checks the token,
               sets Host: 127.0.0.1

lightpanda listens only on 127.0.0.1, so lighttpd is the only way in. init
only configures `eth0`, so a `wait` line in `init.conf` brings up the
loopback interface with busybox first. lightpanda 1.1.0 refuses a bare
`Host: localhost` (without a port), which is why lighttpd sends `127.0.0.1`.

## Security

The VM is the sandbox: a page that exploits the browser gets a VM with no
shell, nothing on its disk worth taking, and a reboot away from a clean
state (rebuild the disk to discard anything written to it). Still:

- Anyone with the token can drive the browser, with the VM's network access.
  It's on the disk in plain text (`/etc/lighttpd/token.conf`), as well as in
  `linux-src/` and `sys/diskimage` (both ignored by git), so treat the disk
  image like the token. Without HTTPS in front (microVM Cloud provides it;
  QEMU's `HOSTFWD` doesn't), the token crosses the network in the clear.
- Getting past lightpanda's `Host` check gives up its DNS rebinding
  protection, which the token takes the place of: a page in someone's
  browser can't send it.
- The guest can reach what its network can. Under QEMU user-mode networking
  that includes the host itself at 10.0.2.2, and under Firecracker whatever
  is on the bridge. To stop pages (or a misled agent) from reaching local
  services, add `--block-private-networks` to the lightpanda command in
  `rootfs/etc/init.conf`; `--block-cidrs` allows exceptions.
- Treat what the browser reads as untrusted input to the agent. The server's
  instructions say so too.

## Shutting down

lightpanda and lighttpd run as `respawn`, so init restarts them if they
crash, and the VM runs until it is killed (Ctrl-A x in QEMU). Nothing on the
disk needs keeping, so that loses nothing that matters.

## Memory

Give it 128MB. A 64MB guest (about 52MB free after boot) boots and loads
simple pages, and even Wikipedia, but a heavy page such as a GitHub releases
page peaks at over 70MB. The kernel then can't allocate network buffers
(`page allocation failure: order:1, mode:0x40820(GFP_ATOMIC|__GFP_COMP)` on
the console), drops packets, and the load drags on for 30s or more: long
enough for a proxy in front, such as microVM Cloud's, to give up with a 504.
At 128MB the same page loads in under 4s. More clients, or heavier
JavaScript sites, need more still.

## What's on the disk

| Path | Purpose |
|------|---------|
| `/usr/bin/lightpanda` | the browser (Zig, with V8 and libcurl built in; links only libc and libm) |
| `/usr/bin/env` | starts lightpanda with `LIGHTPANDA_DISABLE_TELEMETRY=true`, since `init.conf` can't set environment variables |
| `/usr/sbin/lighttpd`, `mod_proxy.so`, `mod_h2.so` | the reverse proxy on port 80 |
| `/etc/lighttpd/lighttpd.conf` | the token check and the proxy to lightpanda |
| `/etc/lighttpd/token.conf` | the token (see [The token](#the-token)), mode 600 |
| `/var/empty` | lighttpd's document root, which it requires but never serves from |
| `/usr/bin/busybox` | brings up `lo` (static, ~2MB) |
| `/etc/ssl/certs/` | CA certificates. Lightpanda reads the individual hashed files here, not the bundle |
| `/etc/resolv.conf` | DNS via 1.1.1.1 and 8.8.8.8 |
| `/.local/share/lightpanda/` | created by lightpanda at startup (init sets `HOME=/`) |
| `/lib`, `/lib64`, ... | glibc and the dynamic loader, from the host |

The disk is 256MB (`DISK_SIZE` in `install.sh`), as the binary alone is too
much for the default 128MB with room to spare.

To serve the Chrome DevTools Protocol instead, for Puppeteer or Playwright,
replace `mcp` and its options in `rootfs/etc/init.conf` with
`serve --host 127.0.0.1 --port 9222` (untested; lighttpd would also need
`mod_wstunnel` or `proxy.header = ( "upgrade" => "enable" )` for the
WebSocket).

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
