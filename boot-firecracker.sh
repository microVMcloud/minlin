#!/usr/bin/env bash
#
# Boot sys/vmlinux (from build-linux.sh) and sys/diskimage (from
# build-disk.sh) under Firecracker.
# Firecracker loads the uncompressed vmlinux (the initramfs is built into it)
# and appends virtio_mmio.device= entries to the kernel command line itself.
# Firecracker exits when the guest resets through its emulated i8042, so
# reboot=k turns init's reboot(RB_AUTOBOOT) into a clean VMM exit.
#
# The guest NIC is backed by a tap device on an existing bridge. If $TAP does
# not exist it is created (via sudo) owned by this user, attached to $BRIDGE,
# and removed again on exit; an existing $TAP is used as-is and left alone.
#
# The guest's address is passed on the kernel command line as
# ip=<client>::<gateway>:<netmask>:<hostname>:eth0:off, which init applies. By default
# it is taken from $BRIDGE's subnet: the gateway is the bridge's own address
# and the guest gets the next address up. Override with GUEST_IP=.
#   BRIDGE=br0 TAP=fctap0 GUEST_IP=172.19.0.50 ./boot-firecracker.sh
#
# Guest RAM is 32MB unless MEM= says otherwise (in MB). The guest's hostname
# is the kernel's default (minlin) unless GUEST_NAME= gives one.
#
# SWAP= names a file made with mkswap (e.g. fallocate -l 256M sys/swapimage &&
# mkswap sys/swapimage) to attach as a second disk, which init swaps onto.
#
# Kernel messages are hidden (loglevel=0) unless --debug is given.

set -euo pipefail

DEBUG=0
args=()
for arg in "$@"; do
    case "$arg" in
        --debug) DEBUG=1 ;;
        *) args+=("$arg") ;;
    esac
done
set -- "${args[@]}"

# loglevel=0 keeps all kernel messages (even KERN_EMERG ones, which quiet
# lets through) off the slow emulated serial console, which
# roughly halves boot time; --debug shows them.
loglevel=loglevel=0
[ "$DEBUG" -eq 1 ] && loglevel=

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SYS_DIR="$SCRIPT_DIR/sys"
BRIDGE="${BRIDGE:-br0}"
TAP="${TAP:-fctap0}"
GUEST_IP="${GUEST_IP:-}"
MEM="${MEM:-32}"
GUEST_NAME="${GUEST_NAME:-}"
SWAP="${SWAP:-}"

if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo "Firecracker needs read/write access to /dev/kvm" >&2
    exit 1
fi

ip2int() {
    local IFS=. a b c d
    read -r a b c d <<<"$1"
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

int2ip() {
    echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"
}

if ! ip link show "$BRIDGE" type bridge >/dev/null 2>&1; then
    echo "Bridge $BRIDGE not found (set BRIDGE=...)" >&2
    exit 1
fi

bridge_cidr="$(ip -4 -o addr show dev "$BRIDGE" | awk '{ print $4; exit }')"
if [ -z "$bridge_cidr" ]; then
    echo "Bridge $BRIDGE has no IPv4 address to derive the guest network from" >&2
    exit 1
fi
gateway="${bridge_cidr%/*}"
prefix="${bridge_cidr#*/}"
mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
netmask="$(int2ip "$mask")"
if [ -z "$GUEST_IP" ]; then
    GUEST_IP="$(int2ip $(( $(ip2int "$gateway") + 1 )))"
fi
guest=$(ip2int "$GUEST_IP")
if [ $(( guest & mask )) -ne $(( $(ip2int "$gateway") & mask )) ] ||
   [ $(( guest | mask )) -eq 4294967295 ] || [ "$GUEST_IP" = "$gateway" ]; then
    echo "Guest address $GUEST_IP is not usable on $bridge_cidr (set GUEST_IP=...)" >&2
    exit 1
fi
echo "Guest network: $GUEST_IP/$prefix via $gateway on $BRIDGE" >&2

as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

created_tap=0
cleanup() {
    rm -f "${config:-}"
    if [ "$created_tap" -eq 1 ]; then
        as_root ip link del "$TAP" || true
    fi
}
trap cleanup EXIT

if ip link show "$TAP" >/dev/null 2>&1; then
    echo "Using existing tap device $TAP" >&2
else
    echo "Creating tap device $TAP on bridge $BRIDGE" >&2
    as_root ip tuntap add dev "$TAP" mode tap user "$(id -un)"
    created_tap=1
    as_root ip link set "$TAP" master "$BRIDGE" up
fi

swap_drive=
if [ -n "$SWAP" ]; then
    [ -f "$SWAP" ] || { echo "SWAP file $SWAP not found" >&2; exit 1; }
    swap_drive=$(printf ', {\n        "drive_id": "swap0",\n        "path_on_host": "%s",\n        "is_root_device": false,\n        "is_read_only": false\n    }' "$(realpath "$SWAP")")
fi

config="$(mktemp --tmpdir firecracker-config.XXXXXX.json)"

# Firecracker's i8042 has only a keyboard port (enough for SendCtrlAltDel);
# these skip the AUX, MUX and PnP probing that otherwise adds ~0.25s to boot.
i8042="i8042.noaux i8042.nomux i8042.nopnp i8042.dumbkbd"

cat > "$config" <<EOF
{
    "boot-source": {
        "kernel_image_path": "$SYS_DIR/vmlinux",
        "boot_args": "console=ttyS0 $loglevel reboot=k panic=1 $i8042 ip=$GUEST_IP::$gateway:$netmask:$GUEST_NAME:eth0:off"
    },
    "drives": [{
        "drive_id": "disk0",
        "path_on_host": "$SYS_DIR/diskimage",
        "is_root_device": false,
        "is_read_only": false
    }$swap_drive],
    "network-interfaces": [{
        "iface_id": "eth0",
        "guest_mac": "10:11:12:00:1A:F4",
        "host_dev_name": "$TAP"
    }],
    "machine-config": {
        "vcpu_count": 1,
        "mem_size_mib": $MEM
    }
}
EOF

firecracker --no-api --config-file "$config"
