#!/usr/bin/env bash
#
# Boot sys/bzImage (from build-linux.sh) and sys/diskimage (from
# build-disk.sh) under QEMU's microvm machine. The initramfs is built into
# the kernel. With acpi=off QEMU appends
# virtio_mmio.device= entries to the kernel command line for each device.
# microvm has no ACPI or i8042 to power off with, so init reboots instead:
# reboot=t makes that a triple fault, which -no-reboot turns into QEMU exiting.
#
# By default the NIC is a socket netdev listening on :1234. Set HOSTFWD to a
# host port to use user-mode networking instead and forward that port to the
# guest's port 80, e.g. to reach lighttpd:
#   HOSTFWD=8080 ./boot-qemu.sh && curl http://localhost:8080/
# SSHFWD does the same for the guest's port 22 (the sshd app), and either one
# or both can be set:
#   SSHFWD=2222 ./boot-qemu.sh && ssh -p 2222 root@localhost
#
# Those ports and :1234 listen on 127.0.0.1 only. BIND_ADDR= names another host
# address to listen on, e.g. BIND_ADDR=0.0.0.0 to open them to the network.
#
# User-mode networking shows the guest the host's loopback as 10.0.2.2, so the
# guest can connect to anything listening on 127.0.0.1 on the host. That is why
# there is no QEMU monitor here: on a TCP port, the guest could drive it.
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

HOSTFWD="${HOSTFWD:-}"
SSHFWD="${SSHFWD:-}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
MEM="${MEM:-32}"
GUEST_NAME="${GUEST_NAME:-}"
SWAP="${SWAP:-}"

kvm_flag=()
[ -w /dev/kvm ] && kvm_flag=(-enable-kvm -cpu host)

if [ -n "$HOSTFWD$SSHFWD" ]; then
    ip="10.0.2.15::10.0.2.2:255.255.255.0:$GUEST_NAME:eth0:off"
    netdev="user,id=testnet1"
    [ -n "$HOSTFWD" ] && netdev+=",hostfwd=tcp:$BIND_ADDR:$HOSTFWD-:80"
    [ -n "$SSHFWD" ] && netdev+=",hostfwd=tcp:$BIND_ADDR:$SSHFWD-:22"
else
    ip="192.168.1.2:::255.255.255.0:$GUEST_NAME:eth0:off"
    netdev="socket,id=testnet1,listen=$BIND_ADDR:1234"
fi

swap_drive=()
if [ -n "$SWAP" ]; then
    [ -f "$SWAP" ] || { echo "SWAP file $SWAP not found" >&2; exit 1; }
    swap_drive=(-drive id=swap0,file="$SWAP",if=none,format=raw
                -device virtio-blk-device,drive=swap0)
fi

qemu-system-x86_64 "${kvm_flag[@]}" -m "${MEM}M" -nographic -nodefaults -no-reboot \
    -M microvm,acpi=off,pcie=off,pic=off,rtc=off \
    -serial stdio \
    -kernel "$SYS_DIR/bzImage" \
    -append "console=ttyS0 $loglevel reboot=t ip=$ip" \
    -drive id=disk0,file="$SYS_DIR/diskimage",if=none,format=raw \
    -device virtio-blk-device,drive=disk0 \
    "${swap_drive[@]}" \
    -netdev "$netdev" \
    -device virtio-net-device,netdev=testnet1,mac=10:11:12:00:1A:F4 \
    -monitor none
