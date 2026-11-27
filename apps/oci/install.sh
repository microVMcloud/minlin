# Sourced by build-disk.sh: downloads a container image from a registry,
# unpacks its layers as the disk, and writes etc/init.conf from the image's
# config (Entrypoint, Cmd, Env and WorkingDir), so init starts what
# `docker run <image>` would.
#
#   IMAGE=caddy:latest ./build-disk.sh oci
#
# IMAGE         required: [registry/]repository[:tag|@sha256:<digest>].
#               Without a registry it is Docker Hub, as with docker pull.
# OCI_PLATFORM  the image to pick from a multi-platform index, default
#               linux/amd64 (the only one the kernel runs).
# OCI_CMD       replaces the image's Entrypoint and Cmd, split on whitespace
#               like any init.conf line.
# OCI_ACTION    the init.conf action, default respawn.
# OCI_ENV       NAME=value pairs, split on whitespace, added after the
#               image's Env so they override it, like docker run -e.
#
# It talks to the registry's HTTP API with curl and jq, so no Docker is needed.
# Only anonymous pulls work. Blobs are kept by digest in $WORKDIR/oci/blobs,
# checked against it, and reused by later builds.

require curl
require jq
require sha256sum coreutils
require gcc
require realpath coreutils

[ -n "${IMAGE:-}" ] || {
    echo "Set IMAGE to the image to run, e.g. IMAGE=caddy:latest ./build-disk.sh oci" >&2
    exit 1
}
oci_action="${OCI_ACTION:-respawn}"
case "$oci_action" in
    wait|once|respawn) ;;
    *) echo "OCI_ACTION must be wait, once or respawn, not '$oci_action'" >&2; exit 1 ;;
esac
oci_os="${OCI_PLATFORM:-linux/amd64}"
oci_arch="${oci_os#*/}"
oci_os="${oci_os%%/*}"
oci_variant=""
[[ "$oci_arch" == */* ]] && { oci_variant="${oci_arch#*/}"; oci_arch="${oci_arch%%/*}"; }

# Split IMAGE the way docker does: a first component with a dot or colon in
# it, or "localhost", is a registry; the tag follows the last colon after
# the last slash.
oci_ref="$IMAGE" oci_digest="" oci_tag="latest"
if [[ "$oci_ref" == *@* ]]; then
    oci_digest="${oci_ref#*@}"
    oci_ref="${oci_ref%%@*}"
fi
if [[ "${oci_ref##*/}" == *:* ]]; then
    oci_tag="${oci_ref##*:}"
    oci_ref="${oci_ref%:*}"
fi
oci_first="${oci_ref%%/*}"
if [[ "$oci_ref" == */* && ( "$oci_first" == *.* || "$oci_first" == *:* || "$oci_first" == localhost ) ]]; then
    oci_registry="$oci_first"
    oci_repo="${oci_ref#*/}"
else
    oci_registry="docker.io"
    oci_repo="$oci_ref"
fi
if [ "$oci_registry" = docker.io ]; then
    oci_api="registry-1.docker.io"
    [[ "$oci_repo" == */* ]] || oci_repo="library/$oci_repo"
else
    oci_api="$oci_registry"
fi
# They become parts of URLs and paths.
[[ "$oci_repo" =~ ^[a-z0-9]+([._/-][a-z0-9]+|__[a-z0-9]+)*$ ]] || {
    echo "Not a repository name: '$oci_repo'" >&2; exit 1; }
[[ "$oci_tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || {
    echo "Not a tag: '$oci_tag'" >&2; exit 1; }
[[ -z "$oci_digest" || "$oci_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "Not a sha256 digest: '$oci_digest'" >&2; exit 1; }
[[ "$oci_api" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || {
    echo "Not a registry host: '$oci_api'" >&2; exit 1; }

oci_cache="$WORKDIR/oci/blobs/sha256"
mkdir -p "$oci_cache"
oci_accept="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
oci_token=""

oci_curl() {
    local auth=()
    [ -z "$oci_token" ] || auth=(-H "Authorization: Bearer $oci_token")
    # curl doesn't send the header on to another host, so blob redirects to
    # a CDN don't get the token.
    curl -fsSL -m 300 "${auth[@]}" "$@"
}

# Get an anonymous pull token if the registry asks for one. Docker Hub
# always does, even for public images.
oci_login() {
    local hdrs status challenge realm service scope
    hdrs="$(curl -sS -m 30 -o /dev/null -D - -H "Accept: $oci_accept" \
        "https://$oci_api/v2/$oci_repo/manifests/${oci_digest:-$oci_tag}")" || {
        echo "Couldn't reach $oci_api" >&2; exit 1; }
    status="$(head -n 1 <<<"$hdrs" | awk '{print $2}')"
    [ "$status" = 401 ] || return 0
    challenge="$(grep -i '^www-authenticate: *bearer ' <<<"$hdrs" | tr -d '\r')" || {
        echo "$oci_api wants a login this script can't do" >&2; exit 1; }
    realm="$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$challenge")"
    service="$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$challenge")"
    scope="$(sed -n 's/.*scope="\([^"]*\)".*/\1/p' <<<"$challenge")"
    [[ "$realm" == https://* ]] || { echo "Unexpected auth realm '$realm'" >&2; exit 1; }
    oci_token="$(curl -fsS -m 30 -G "$realm" --data-urlencode "service=$service" \
        --data-urlencode "scope=${scope:-repository:$oci_repo:pull}" |
        jq -r '.token // .access_token // empty')"
    [ -n "$oci_token" ] || { echo "No pull token for $oci_repo from $realm" >&2; exit 1; }
}

# Fetch a manifest into a file. One asked for by digest is checked against it.
oci_manifest() {
    local ref="$1" out="$2"
    oci_curl -H "Accept: $oci_accept" -o "$out" "https://$oci_api/v2/$oci_repo/manifests/$ref"
    if [[ "$ref" == sha256:* ]]; then
        echo "${ref#sha256:}  $out" | sha256sum --check --quiet --strict
    fi
}

# Make sure a blob is in the cache, downloading and checking it if not.
oci_fetch_blob() {
    local digest="$1" path
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "Bad blob digest '$digest'" >&2; exit 1; }
    path="$oci_cache/${digest#sha256:}"
    [ -f "$path" ] && return 0
    oci_curl -o "$path.part" "https://$oci_api/v2/$oci_repo/blobs/$digest"
    echo "${digest#sha256:}  $path.part" | sha256sum --check --quiet --strict
    mv "$path.part" "$path"
}

log "Fetching $oci_registry/$oci_repo:$oci_tag${oci_digest:+@$oci_digest} for $oci_os/$oci_arch${oci_variant:+/$oci_variant}"
oci_login
oci_tmp="$(mktemp -d "$WORKDIR/oci/tmp.XXXXXX")"
oci_manifest "${oci_digest:-$oci_tag}" "$oci_tmp/manifest.json"
if jq -e '.manifests' "$oci_tmp/manifest.json" >/dev/null; then
    oci_pick="$(jq -r --arg os "$oci_os" --arg arch "$oci_arch" --arg v "$oci_variant" '
        [.manifests[] | select(.platform.os == $os and .platform.architecture == $arch
            and ($v == "" or .platform.variant == $v))][0].digest // empty' "$oci_tmp/manifest.json")"
    [ -n "$oci_pick" ] || {
        echo "$IMAGE has no $oci_os/$oci_arch image. It has:" >&2
        jq -r '.manifests[].platform | "  \(.os)/\(.architecture)\(if .variant then "/" + .variant else "" end)"' \
            "$oci_tmp/manifest.json" >&2
        exit 1
    }
    oci_manifest "$oci_pick" "$oci_tmp/manifest.json"
    echo "Image manifest: $oci_pick"
fi

oci_config="$(jq -r '.config.digest' "$oci_tmp/manifest.json")"
oci_fetch_blob "$oci_config"
oci_config="$oci_cache/${oci_config#sha256:}"
oci_cfg_arch="$(jq -r '.architecture' "$oci_config")"
[ "$oci_cfg_arch" = "$oci_arch" ] || {
    echo "The image is for $oci_cfg_arch, not $oci_arch" >&2; exit 1; }

# The layers are untrusted, and they're unpacked on the host. GNU tar strips
# a leading / and refuses .., and holds back symlinks that point outside
# until the end of each archive. It still follows symlinks left on disk by an
# earlier layer, so a layer could write through one to anywhere the build
# user can. Refuse a layer that would: every directory its entries (and hard
# link targets) pass through must resolve to somewhere inside the rootfs.
oci_root="$(realpath "$ROOTFS")"
oci_check_layer() {
    local list="$1" bad
    if grep -qE '(^|/)\.\.(/|$)' "$list"; then
        echo "A layer has a path with '..' in it:" >&2
        grep -E '(^|/)\.\.(/|$)' "$list" | head -n 5 >&2
        exit 1
    fi
    bad="$(awk -F/ '{ p = $1; for (i = 2; i <= NF; i++) { print p; p = p "/" $i } }' "$list" |
        sort -u | while IFS= read -r d; do
            [ -L "$oci_root/$d" ] || continue
            r="$(realpath -m -- "$oci_root/$d")"
            case "$r/" in "$oci_root"/*) ;; *) printf '%s -> %s\n' "$d" "$(readlink "$oci_root/$d")" ;; esac
        done)"
    if [ -n "$bad" ]; then
        echo "A layer writes through a symlink that leads out of the rootfs:" >&2
        head -n 5 <<<"$bad" >&2
        echo "Docker would resolve it inside the container; this script doesn't." >&2
        exit 1
    fi
}

# A non-root build can't write into a directory a layer made read-only,
# such as a 0555 /proc, so open them up while later layers go in and put
# the modes back at the end.
: >"$oci_tmp/modes"
oci_open_dirs() {
    find "$oci_root" -type d ! -perm -u=rwx -printf '%m %P\0' >>"$oci_tmp/modes"
    find "$oci_root" -type d ! -perm -u=rwx -exec chmod u+rwx {} +
}

oci_n=0
oci_layers="$(jq -r '.layers | length' "$oci_tmp/manifest.json")"
while IFS=$'\t' read -r oci_ldigest oci_ltype oci_lsize; do
    oci_n=$((oci_n + 1))
    log "Layer $oci_n/$oci_layers: $oci_ldigest ($((oci_lsize / 1024)) KiB)"
    case "$oci_ltype" in
        *nondistributable*|*foreign*)
            echo "Layer $oci_ldigest is a foreign layer, which registries don't serve" >&2; exit 1 ;;
        *tar+gzip|*tar.gzip) oci_comp=(-z) ;;
        *tar+zstd) require zstd; oci_comp=(--zstd) ;;
        *.tar|*tar) oci_comp=() ;;
        *) echo "Unknown layer type $oci_ltype" >&2; exit 1 ;;
    esac
    oci_fetch_blob "$oci_ldigest"
    oci_blob="$oci_cache/${oci_ldigest#sha256:}"
    # Paths as tar will write them: without ./ or a leading /, or a
    # directory's trailing /.
    tar "${oci_comp[@]}" -tvf "$oci_blob" --quoting-style=literal |
        sed -n 's/.* link to //p' >"$oci_tmp/links"
    tar "${oci_comp[@]}" -tf "$oci_blob" --quoting-style=literal |
        cat - "$oci_tmp/links" |
        sed -e 's|^/*||' -e 's|^\(\./\)*||' -e 's|/*$||' | grep -v '^\.\?$' >"$oci_tmp/list" || true
    oci_check_layer "$oci_tmp/list"
    # Whiteouts delete what lower layers put there: .wh.<name> removes
    # <name>, and .wh..wh..opq empties its directory.
    while IFS= read -r oci_wh; do
        oci_dir="$(dirname "$oci_wh")"
        oci_name="$(basename "$oci_wh")"
        [ "$oci_dir" = . ] && oci_dir=""
        if [ "$oci_name" = .wh..wh..opq ]; then
            [ -d "$oci_root/$oci_dir" ] && find "$oci_root/$oci_dir" -mindepth 1 -delete
        else
            rm -rf -- "$oci_root/${oci_dir:+$oci_dir/}${oci_name#.wh.}"
        fi
    done < <(grep -E '(^|/)\.wh\.[^/]+$' "$oci_tmp/list" || true)
    tar "${oci_comp[@]}" -xpf "$oci_blob" -C "$oci_root" --no-same-owner \
        --exclude='.wh.*' --exclude='*/.wh.*'
    oci_open_dirs
done < <(jq -r '.layers[] | [.digest, .mediaType, .size] | @tsv' "$oci_tmp/manifest.json")
# Restore in reverse, so a directory listed twice ends with its first mode.
tr '\0' '\n' <"$oci_tmp/modes" | tac | while read -r oci_mode oci_path; do
    chmod "$oci_mode" "$oci_root/$oci_path"
done

# --- What to run ------------------------------------------------------------

mapfile -t oci_env < <(jq -r '.config.Env // [] | .[]' "$oci_config")
if [ -n "${OCI_ENV:-}" ]; then
    read -ra oci_extra <<<"$OCI_ENV"
    for oci_e in "${oci_extra[@]}"; do
        [[ "$oci_e" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || {
            echo "OCI_ENV: '$oci_e' isn't NAME=value" >&2; exit 1; }
    done
    # /minlin/run sets them in order, so these win over the image's.
    oci_env+=("${oci_extra[@]}")
fi
if [ -n "${OCI_CMD:-}" ]; then
    read -ra oci_argv <<<"$OCI_CMD"
else
    mapfile -t oci_argv < <(jq -r '(.config.Entrypoint // []) + (.config.Cmd // []) | .[]' "$oci_config")
fi
oci_workdir="$(jq -r '.config.WorkingDir // ""' "$oci_config")"
oci_user="$(jq -r '.config.User // ""' "$oci_config")"
[ "${#oci_argv[@]}" -gt 0 ] || {
    echo "The image has no Entrypoint or Cmd. Set OCI_CMD." >&2; exit 1; }
for oci_a in "${oci_argv[@]}"; do
    [[ "$oci_a" =~ [[:space:]] || -z "$oci_a" ]] && {
        echo "init.conf can't quote the argument '$oci_a' from the image's command:" >&2
        printf '  %s\n' "${oci_argv[*]}" >&2
        echo "Set OCI_CMD, or point it at a wrapper script run by the image's shell." >&2
        exit 1
    }
done
# Docker sets HOME from the user's passwd entry, which is /root for root.
printf '%s\n' "${oci_env[@]}" | grep -q '^HOME=' || oci_env+=("HOME=/root")
oci_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
oci_keep=()
for oci_e in "${oci_env[@]}"; do
    if [[ "$oci_e" =~ [[:space:]] ]]; then
        echo "WARNING: dropping ${oci_e%%=*} from the environment: init.conf can't quote its value" >&2
        continue
    fi
    [[ "$oci_e" == PATH=* ]] && oci_path="${oci_e#PATH=}"
    oci_keep+=("$oci_e")
done
[ -z "$oci_user" ] || [ "$oci_user" = root ] || [ "$oci_user" = 0 ] || [ "$oci_user" = 0:0 ] ||
    echo "WARNING: the image runs as user '$oci_user', but init runs it as root" >&2

# Find the program on the disk the way execvp will, to check it can start.
oci_prog="${oci_argv[0]}"
if [[ "$oci_prog" != */* ]]; then
    oci_found=""
    IFS=: read -ra oci_dirs <<<"$oci_path"
    for oci_d in "${oci_dirs[@]}"; do
        oci_f="$(rootfs_path "$oci_d/$oci_prog")"
        if [ -f "$oci_f" ] && [ -x "$oci_f" ]; then oci_found="$oci_d/$oci_prog"; break; fi
    done
    [ -n "$oci_found" ] || { echo "$oci_prog isn't on the image's PATH ($oci_path)" >&2; exit 1; }
    oci_prog="$oci_found"
elif [[ "$oci_prog" != /* ]]; then
    oci_prog="${oci_workdir:-/}/$oci_prog"
fi
oci_argv[0]="$oci_prog"
# The kernel can't run scripts, so start a script's interpreter the way
# the kernel would have: interpreter, its one optional argument, the script.
oci_file="$(rootfs_path "$oci_prog")"
if [ "$(head -c 2 "$oci_file")" = '#!' ]; then
    read -r oci_interp oci_iarg < <(head -n 1 "$oci_file" | sed 's/^#![[:space:]]*//')
    [[ "${oci_iarg:-}" =~ [[:space:]] ]] && {
        echo "$oci_prog's #! line has more than one argument" >&2; exit 1; }
    echo "$oci_prog is a script: starting it with $oci_interp${oci_iarg:+ $oci_iarg}"
    oci_argv=("$oci_interp" ${oci_iarg:+"$oci_iarg"} "${oci_argv[@]}")
    oci_file="$(rootfs_path "$oci_interp")"
fi
[ -f "$oci_file" ] && [ "$(head -c 4 "$oci_file")" = $'\x7fELF' ] || {
    echo "${oci_argv[0]} isn't an ELF binary on the disk" >&2; exit 1; }

# /minlin/run points /dev/shm here (see src/run.c).
mkdir -p "$ROOTFS/minlin/shm" "$ROOTFS/etc"
gcc -static -Os -s -o "$ROOTFS/minlin/run" "$APP_DIR/src/run.c"
# Docker writes these into every container at run time.
[ -s "$ROOTFS/etc/resolv.conf" ] || printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >"$ROOTFS/etc/resolv.conf"
[ -s "$ROOTFS/etc/hosts" ] || printf '127.0.0.1\tlocalhost\n' >"$ROOTFS/etc/hosts"

oci_line="$oci_action /minlin/run${oci_workdir:+ -C $oci_workdir} ${oci_keep[*]} -- ${oci_argv[*]}"
read -ra oci_words <<<"$oci_line"
[ "$((${#oci_words[@]} - 1))" -le 32 ] && [ "${#oci_line}" -le 511 ] || {
    echo "The command is too long for init.conf (32 arguments, 511 characters):" >&2
    echo "  $oci_line" >&2
    exit 1
}
rm -f "$ROOTFS/etc/init.conf"
cat >"$ROOTFS/etc/init.conf" <<EOF
# Programs for init to start once the disk is mounted as /.
# Each line is "<action> <absolute path> [args...]", run in order:
#   wait     run it and wait for it to exit before going on
#   once     start it and leave it running
#   respawn  start it, and start it again whenever it exits
# When nothing is left running, init syncs the disk and reboots (which ends
# the VM).

# Written by apps/oci/install.sh from $IMAGE
# ($(jq -r '.config.digest' "$oci_tmp/manifest.json")).
# /minlin/run sets the image's WorkingDir and Env, then runs its command.
$oci_line
EOF
echo "init.conf: $oci_line"
jq -r '.config.ExposedPorts // {} | keys[]' "$oci_config" | while read -r oci_p; do
    case "$oci_p" in 80/tcp|22/tcp|5432/tcp|53/tcp|53/udp|6379/tcp) ;; *)
        echo "Note: the image exposes $oci_p, which boot-qemu.sh doesn't forward" ;; esac
done
rm -rf "$oci_tmp"

# Room for the files plus ext4's own overhead, which is large on a small disk.
oci_mb="$(du -sm "$ROOTFS" | cut -f1)"
DISK_SIZE="$((oci_mb * 3 / 2 + 32))M"
