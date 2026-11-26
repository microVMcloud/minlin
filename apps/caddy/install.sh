# Sourced by build-disk.sh: installs the host's caddy (a Go binary needing
# only libc), coreutils' env to point its state directories at /var/lib, and
# that directory.
#
# By default Caddy serves plain HTTP on port 80. Set CADDY_DOMAIN to a domain
# name to serve it over HTTPS instead, with a certificate Caddy gets from
# Let's Encrypt (or ZeroSSL) and renews itself. The domain must resolve to
# the VM, and the VM's ports 80 and 443 must be reachable from the internet
# for the CA to check it. The disk then also gets DNS servers and the host's
# CA certificates, for talking to the CA.
#   CADDY_EMAIL    optional contact address for the ACME account, which the
#                  CA uses for expiry warnings
#   CADDY_STAGING  set to 1 to use Let's Encrypt's staging CA, whose
#                  certificates browsers don't trust but which has no tight
#                  rate limits. Use it while getting the setup working.
# A local name such as CADDY_DOMAIN=localhost gets a certificate from a CA
# Caddy makes itself, which needs no internet access.
#
# Caddy keeps certificates and its ACME account in /var/lib/caddy on the
# disk. Each build copies that directory out of the old sys/diskimage into
# $WORKDIR/caddy_data first, and puts it on the new disk, so rebuilding
# doesn't request new certificates (Let's Encrypt allows 5 per week for the
# same name).

require caddy
require debugfs e2fsprogs

install_binary "$(command -v caddy)"
# init.conf lines can't set environment variables, so go through env.
install_binary "$(command -v env)"
mkdir -p "$ROOTFS/var/lib/caddy"

# Save the old disk's state before build-disk.sh replaces it. Only a disk
# holding certificates replaces what's saved, so building another app in
# between doesn't lose them.
caddy_state="$WORKDIR/caddy_data"
old_disk="$SCRIPT_DIR/sys/diskimage"
if [ -r "$old_disk" ]; then
    dump="$(umask 077 && mktemp -d "$WORKDIR/caddy_dump.XXXXXX")"
    # debugfs exits 0 even when the path isn't there, so look at the result.
    debugfs -R "rdump /var/lib/caddy $dump" "$old_disk" >/dev/null 2>&1 || true
    # A VM killed before the kernel wrote a new file's data leaves it empty,
    # and an empty root certificate makes caddy exit at startup. Caddy makes
    # a missing file again.
    find "$dump" -type f -empty -delete
    if [ -n "$(find "$dump/caddy/certificates" -type f -print -quit 2>/dev/null)" ]; then
        rm -rf "$caddy_state"
        mv "$dump/caddy" "$caddy_state"
        chmod 700 "$caddy_state"
        log "Kept Caddy's certificates from the old disk in $caddy_state"
    fi
    rm -rf "$dump"
fi

if [ -n "${CADDY_DOMAIN:-}" ]; then
    # It goes into the Caddyfile as a site address, so allow host names only.
    [[ "$CADDY_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || {
        echo "CADDY_DOMAIN must be a host name, e.g. example.com" >&2
        exit 1
    }
    [ -z "${CADDY_EMAIL:-}" ] || [[ "$CADDY_EMAIL" =~ ^[^[:space:]{}\"]+@[^[:space:]{}\"]+$ ]] || {
        echo "CADDY_EMAIL must be an email address" >&2
        exit 1
    }
    caddyfile="$ROOTFS/etc/caddy/Caddyfile"
    sed -i -e '/^\t# A bare port leaves nothing/d' -e '/^\tauto_https off$/d' \
        -e "s/^:80 {\$/$CADDY_DOMAIN {/" "$caddyfile"
    [ -z "${CADDY_EMAIL:-}" ] || sed -i "s/^\tadmin off\$/&\n\temail $CADDY_EMAIL/" "$caddyfile"
    [ "${CADDY_STAGING:-0}" != 1 ] ||
        sed -i 's|^\tadmin off$|&\n\tacme_ca https://acme-staging-v02.api.letsencrypt.org/directory|' "$caddyfile"
    # Fail the build here rather than have caddy crash-loop in the guest.
    caddy adapt --config "$caddyfile" --adapter caddyfile >/dev/null

    # Caddy doesn't fsync what it writes, and the kernel's default is to
    # write it back after about 30s, so a VM killed in that time loses new
    # keys and certificates. This shortens it to about a second.
    printf 'vm.dirty_expire_centisecs = 100\nvm.dirty_writeback_centisecs = 100\n' \
        > "$ROOTFS/etc/sysctl.conf"
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$ROOTFS/etc/resolv.conf"
    cp --parents -L /etc/ssl/certs/ca-certificates.crt "$ROOTFS"
    if [ -d "$caddy_state" ]; then
        cp -a "$caddy_state/." "$ROOTFS/var/lib/caddy/"
        # Stale and unused: caddy runs from the Caddyfile, not --resume, and
        # locks are only left behind by a VM that was killed.
        rm -rf "$ROOTFS/var/lib/caddy/autosave.json" "$ROOTFS/var/lib/caddy/locks"
    fi
    chmod 700 "$ROOTFS/var/lib/caddy"
fi
