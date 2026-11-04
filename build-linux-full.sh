#!/usr/bin/env bash
#
# Build a full (defconfig) Linux kernel with the same hand-written init as
# build-linux.sh.
#
# Downloads the Linux source tarball, compiles a small static init.c (with musl
# when available), embeds it as the kernel's built-in initramfs, and
# configures a stock x86_64_defconfig plus kvm_guest.config, adding the few
# options init and the apps rely on (virtio-mmio, devtmpfs, TUN, nftables NAT).
# Nothing is stripped out, so the kernel is several MB larger and needs more
# guest RAM than the minimal one (boot with MEM=64 or more).
#
# The source tree lives in linux-full next to build-linux.sh's linux tree, so
# both can be kept. A successful build copies bzImage (for QEMU) and vmlinux
# (for Firecracker) into sys/, replacing the minimal kernel there.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
WORKDIR="${1:-$PWD/linux-src}"
KERNEL_DIR="$WORKDIR/linux-full"
SYS_DIR="$SCRIPT_DIR/sys"
JOBS="$(nproc)"
KERNEL_VERSION="7.3.1" # 6.18.60 also tested as it is LTS
# From sha256sums.asc beside the tarball on kernel.org. Change it with KERNEL_VERSION.
KERNEL_SHA256="d0f6b1d7324c937ccaeb5c4ca7084bfcf71db2edb3e2d3a31f0ad83a681809ab"
KERNEL_TARBALL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VERSION%%.*}.x/linux-${KERNEL_VERSION}.tar.xz"
KERNEL_TARBALL="$SCRIPT_DIR/linux-${KERNEL_VERSION}.tar.xz"

log() { printf '\n>>> %s\n' "$*"; }

check_deps() {
    local missing=()
    for tool in curl sha256sum tar xz make gcc bc flex bison qemu-system-x86_64; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    # objtool needs libelf headers, which are a library, not a tool.
    echo "#include <gelf.h>" | gcc -E - >/dev/null 2>&1 || missing+=("libelf-dev")
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Missing requirements: ${missing[*]}" >&2
        echo "On Debian/Ubuntu: sudo apt install curl coreutils xz-utils build-essential bc flex bison qemu-system-x86 libelf-dev" >&2
        exit 1
    fi
}

# A kernel from a bad tarball would otherwise build and boot without complaint.
verify_tarball() {
    local file="$1" actual
    actual="$(sha256sum "$file" | cut -d' ' -f1)"
    [ "$actual" = "$KERNEL_SHA256" ] && return 0
    echo "SHA-256 mismatch for $file" >&2
    echo "  expected $KERNEL_SHA256" >&2
    echo "  actual   $actual" >&2
    echo "If KERNEL_VERSION changed, update KERNEL_SHA256 from" >&2
    echo "  ${KERNEL_TARBALL_URL%/*}/sha256sums.asc" >&2
    return 1
}

fetch_kernel() {
    if [ -d "$KERNEL_DIR" ]; then
        log "Kernel source already present at $KERNEL_DIR, skipping download"
        return
    fi

    if [ ! -f "$KERNEL_TARBALL" ]; then
        log "Downloading Linux v$KERNEL_VERSION into $KERNEL_TARBALL"
        # Download beside the real name, so an interrupted download can't pass
        # as a tarball that's already present. This name is ignored by git too.
        local partial="${KERNEL_TARBALL%.tar.xz}.part.tar.xz"
        curl -fL -o "$partial" "$KERNEL_TARBALL_URL"
        verify_tarball "$partial" || { rm -f "$partial"; exit 1; }
        mv "$partial" "$KERNEL_TARBALL"
    else
        log "Tarball already present at $KERNEL_TARBALL, skipping download"
        verify_tarball "$KERNEL_TARBALL" || {
            echo "Otherwise delete the tarball to download it again." >&2
            exit 1
        }
    fi

    log "Extracting kernel source into $KERNEL_DIR"
    tar -xJf "$KERNEL_TARBALL" -C "$WORKDIR"
    mv "$WORKDIR/linux-${KERNEL_VERSION}" "$KERNEL_DIR"
}

# x86-64 allocates struct pages for whole 128MB memory sections and maps them
# with 2MB huge pages, so even a 32MB guest pays 2MB for its memmap. Shrink
# sections to 32MB and map the memmap with 4K pages so it costs only what the
# guest's RAM needs (512KB for 32MB), freeing ~1.5MB.
patch_kernel() {
    log "Patching x86-64 sparsemem to size the memmap to guest RAM"
    sed -i 's/^# define SECTION_SIZE_BITS\t27 .*/# define SECTION_SIZE_BITS\t25/' \
        "$KERNEL_DIR/arch/x86/include/asm/sparsemem.h"
    sed -i 's/^\telse if (boot_cpu_has(X86_FEATURE_PSE))$/\telse if (0 \&\& boot_cpu_has(X86_FEATURE_PSE))/' \
        "$KERNEL_DIR/arch/x86/mm/init_64.c"
    grep -q $'^# define SECTION_SIZE_BITS\t25$' "$KERNEL_DIR/arch/x86/include/asm/sparsemem.h" &&
        grep -q '0 && boot_cpu_has(X86_FEATURE_PSE)' "$KERNEL_DIR/arch/x86/mm/init_64.c" || {
        echo "Kernel patch did not apply; the sparsemem/vmemmap source has changed." >&2
        exit 1
    }

    # Go programs reserve tens of MB of address space up front, which the
    # default heuristic overcommit refuses outright on a 32MB guest with no
    # swap. Make "always overcommit" the built-in default rather than leave
    # every Go app to set vm.overcommit_memory in its /etc/sysctl.conf.
    log "Patching the overcommit policy default to always"
    sed -i 's/^int sysctl_overcommit_memory __read_mostly = OVERCOMMIT_GUESS;$/int sysctl_overcommit_memory __read_mostly = OVERCOMMIT_ALWAYS;/' \
        "$KERNEL_DIR/mm/util.c"
    grep -q '^int sysctl_overcommit_memory __read_mostly = OVERCOMMIT_ALWAYS;$' "$KERNEL_DIR/mm/util.c" || {
        echo "Kernel patch did not apply; the overcommit default in mm/util.c has changed." >&2
        exit 1
    }
}

configure_kernel() {
    log "Generating x86_64_defconfig with kvm_guest.config"
    make -C "$KERNEL_DIR" ARCH=x86_64 x86_64_defconfig kvm_guest.config

    # init needs a console on ttyS0, devtmpfs and an ext4 root on virtio-blk.
    # Firecracker has no PCI bus, so its virtio devices come from
    # virtio_mmio.device= on the command line. Anything defconfig leaves as a
    # module is useless here (there is no module tree), so build it in.
    # PANIC_TIMEOUT: the default of 0 leaves a panicked VM hanging forever, and
    # loglevel=0 hides the message. Rebooting ends the VM under any VMM.
    log "Enabling options needed for console, devtmpfs and virtio-mmio disk/net"
    "$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
        --enable DEVTMPFS \
        --enable DEVTMPFS_MOUNT \
        --enable SERIAL_8250 \
        --enable SERIAL_8250_CONSOLE \
        --enable VIRTIO_MENU \
        --enable VIRTIO \
        --enable VIRTIO_MMIO \
        --enable VIRTIO_MMIO_CMDLINE_DEVICES \
        --enable VIRTIO_BLK \
        --enable VIRTIO_NET \
        --enable EXT4_FS \
        --set-val PANIC_TIMEOUT 1 \
        --set-val LOCALVERSION '""' \
        --disable LOCALVERSION_AUTO \
        --set-str DEFAULT_HOSTNAME minlin

    # Tailscale needs a TUN device and policy routing, and as an exit node
    # masquerades forwarded traffic with nftables.
    log "Enabling TUN, policy routing and nftables NAT for Tailscale"
    "$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
        --enable TUN \
        --enable IP_ADVANCED_ROUTER \
        --enable IP_MULTIPLE_TABLES \
        --enable NETFILTER \
        --enable NF_CONNTRACK \
        --enable NF_NAT \
        --enable NF_TABLES \
        --enable NF_TABLES_IPV4 \
        --enable NFT_CT \
        --enable NFT_NAT \
        --enable NFT_MASQ

    log "Embedding init as an uncompressed built-in initramfs"
    "$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
        --enable BLK_DEV_INITRD \
        --set-str INITRAMFS_SOURCE "$WORKDIR/initramfs.list" \
        --enable INITRAMFS_COMPRESSION_NONE

    log "Resolving dependencies with olddefconfig"
    make -C "$KERNEL_DIR" ARCH=x86_64 olddefconfig
}

build_kernel() {
    log "Building kernel (-j$JOBS)"
    make -C "$KERNEL_DIR" ARCH=x86_64 -j"$JOBS"
}

install_kernel() {
    log "Copying bzImage and vmlinux into $SYS_DIR"
    mkdir -p "$SYS_DIR"
    cp "$KERNEL_DIR/arch/x86/boot/bzImage" "$KERNEL_DIR/vmlinux" "$SYS_DIR/"
}

write_init() {
    log "Copying init.c"
    cp "$SCRIPT_DIR/init.c" "$WORKDIR/init.c"
}

build_init() {
    # init stays resident in the initramfs, so prefer musl: a static glibc
    # binary is ~850KB of guest RAM versus a few tens of KB with musl.
    local cc=musl-gcc
    if ! command -v "$cc" >/dev/null 2>&1; then
        echo "WARNING: musl-gcc not found, falling back to static glibc (much larger init)." >&2
        echo "         On Debian/Ubuntu: sudo apt install musl-tools" >&2
        cc=gcc
    fi

    log "Compiling init statically with $cc"
    "$cc" -Os -static -s -Wall -fno-asynchronous-unwind-tables \
        -o "$WORKDIR/init" "$WORKDIR/init.c"
}

write_initramfs_list() {
    log "Writing initramfs file list"
    printf '%s\n' \
        'dir /dev 0755 0 0' \
        'nod /dev/console 0600 0 0 c 5 1' \
        "file /init $WORKDIR/init 0755 0 0" \
        > "$WORKDIR/initramfs.list"
}

boot_qemu() {
    log "Booting under QEMU"
    "$SCRIPT_DIR/boot-qemu.sh" "$WORKDIR"
}

# Start the kernel build from scratch.
rm -rf "$KERNEL_DIR" "$WORKDIR/init" "$WORKDIR/init.c" "$WORKDIR/initramfs.list"
mkdir -p "$WORKDIR"
check_deps
fetch_kernel
patch_kernel
write_init
build_init
write_initramfs_list
configure_kernel
build_kernel
install_kernel
#boot_qemu
