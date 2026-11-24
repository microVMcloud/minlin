# Sourced by build-disk.sh: downloads Xray-core's static linux-64 release
# (a single Go binary), checks it against the release's published SHA-256,
# and writes a VLESS + REALITY server config listening on guest port 80.
#
# The release is cached in the work directory (linux-src/xray/<version>/), so
# rebuilding doesn't download it again unless a newer release is out.
#
# The client UUID, REALITY key pair and short ID are generated on the first
# build and kept in linux-src/xray_reality.env, so rebuilding keeps them and
# existing clients keep working. The file has the same format as the
# /opt/xray/reality.env that the by-hand setup writes in the guest, so copying
# that one in keeps a VM's existing keys. Delete it to make new ones.
#
# Settings:
#   XRAY_VERSION  release tag to install, such as v25.10.15 (default: latest)
#   XRAY_SNI      site REALITY impersonates; it must support TLS 1.3 and
#                 HTTP/2 and be reachable from the guest
#                 (default: www.microsoft.com)
#   XRAY_HOST, XRAY_PORT
#                 the address clients connect to, used only for the vless://
#                 link the build prints (default: localhost and 8080, for
#                 HOSTFWD=8080)

require curl
require unzip
require openssl
require sha256sum coreutils

xray_base=https://github.com/XTLS/Xray-core/releases
xray_ver="${XRAY_VERSION:-latest}"
if [ "$xray_ver" = latest ]; then
    # The latest/ URL redirects to .../tag/<version>.
    xray_ver="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$xray_base/latest")"
    xray_ver="${xray_ver##*/}"
fi
# It goes into a path and a URL.
[[ "$xray_ver" =~ ^v[0-9][0-9A-Za-z.-]*$ ]] || {
    echo "Unexpected Xray version '$xray_ver'" >&2
    exit 1
}

xray_cache="$WORKDIR/xray/$xray_ver"
if [ ! -x "$xray_cache/xray" ]; then
    log "Downloading Xray $xray_ver"
    xray_dl="$(mktemp -d "$WORKDIR/xray-dl.XXXXXX")"
    curl -fsSL -o "$xray_dl/x.zip" "$xray_base/download/$xray_ver/Xray-linux-64.zip"
    curl -fsSL -o "$xray_dl/x.zip.dgst" "$xray_base/download/$xray_ver/Xray-linux-64.zip.dgst"
    # The .dgst file lists several hashes, one per line, as "SHA2-256= <hex>".
    awk '/^SHA2-256=/ {print $2 "  x.zip"}' "$xray_dl/x.zip.dgst" >"$xray_dl/sha256"
    [ -s "$xray_dl/sha256" ] || { echo "No SHA2-256 line in the release's .dgst file" >&2; exit 1; }
    (cd "$xray_dl" && sha256sum -c --quiet sha256)
    unzip -q "$xray_dl/x.zip" xray -d "$xray_dl"
    mkdir -p "$xray_cache"
    install -m 755 "$xray_dl/xray" "$xray_cache/xray"
    rm -rf "$xray_dl"
fi
mkdir -p "$ROOTFS/usr/local/bin"
install -m 755 "$xray_cache/xray" "$ROOTFS/usr/local/bin/xray"

# The raw 32-byte X25519 keys, in the unpadded base64url that "xray x25519"
# prints. openssl makes them so the build host needn't be able to run the
# linux-64 binary. Both DER encodings end with the raw key.
b64url() { base64 | tr '+/' '-_' | tr -d '=\n'; }
xray_state="$WORKDIR/xray_reality.env"
if [ ! -f "$xray_state" ]; then
    log "Generating REALITY keys in $xray_state"
    xray_pem="$(openssl genpkey -algorithm X25519)"
    # The umask only covers files opened inside the subshell, so the redirect
    # goes there too. Writing beside the file and moving it into place means a
    # failure leaves no half-written state for the next build to trust.
    (
        umask 077
        exec >"$xray_state.new"
        printf 'uuid=%s\n' "$(cat /proc/sys/kernel/random/uuid)"
        printf 'priv=%s\n' "$(printf '%s\n' "$xray_pem" | openssl pkey -outform DER | tail -c 32 | b64url)"
        printf 'pub=%s\n' "$(printf '%s\n' "$xray_pem" | openssl pkey -pubout -outform DER | tail -c 32 | b64url)"
        printf 'sid=%s\n' "$(openssl rand -hex 8)"
    )
    mv "$xray_state.new" "$xray_state"
    unset xray_pem
fi
chmod 600 "$xray_state"
uuid="" priv="" pub="" sid=""
# shellcheck source=/dev/null
source "$xray_state"
# They go into JSON strings and a URL, and a bad one only shows up when the
# guest's xray refuses the config.
[[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || { echo "$xray_state: bad uuid" >&2; exit 1; }
[[ "$priv" =~ ^[A-Za-z0-9_-]{43}$ ]] || { echo "$xray_state: bad priv" >&2; exit 1; }
[[ "$pub" =~ ^[A-Za-z0-9_-]{43}$ ]] || { echo "$xray_state: bad pub" >&2; exit 1; }
[[ "$sid" =~ ^([0-9a-f]{2}){0,8}$ ]] || { echo "$xray_state: bad sid" >&2; exit 1; }

xray_sni="${XRAY_SNI:-www.microsoft.com}"
[[ "$xray_sni" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "XRAY_SNI must be a hostname" >&2; exit 1; }

# Connections without the key are passed on to $xray_sni, so a scanner sees
# that site. The block rule stops clients reaching private addresses through
# the proxy: under QEMU, 10.0.2.2 is the host's loopback, and on cloud VMs
# 169.254.169.254 is usually the metadata service. IPOnDemand resolves domain
# names first, so a name pointing at one of them is blocked too. The kernel
# has no IPv6, hence UseIPv4.
mkdir -p "$ROOTFS/etc/xray"
(
    umask 077
    cat >"$ROOTFS/etc/xray/config.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0", "port": 80, "protocol": "vless",
    "settings": {"clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}],
                 "decryption": "none"},
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {"dest": "$xray_sni:443", "serverNames": ["$xray_sni"],
                          "privateKey": "$priv", "shortIds": ["$sid"]}
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {"domainStrategy": "IPOnDemand", "rules": [
    {"outboundTag": "block", "ip": ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12",
      "192.168.0.0/16", "169.254.0.0/16", "100.64.0.0/10", "0.0.0.0/8"]}
  ]}
}
EOF
)

# Catch a config xray would refuse at build time, when the host can run it.
if [ "$(uname -sm)" = "Linux x86_64" ]; then
    "$ROOTFS/usr/local/bin/xray" run -test -c "$ROOTFS/etc/xray/config.json" >/dev/null
fi

echo "Xray $xray_ver client link (keys in $xray_state):"
echo "vless://$uuid@${XRAY_HOST:-localhost}:${XRAY_PORT:-8080}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$xray_sni&fp=chrome&pbk=$pub&sid=$sid&type=tcp#minlin"
