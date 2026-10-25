#!/usr/bin/env bash
#
# Build and boot a "naked" Linux kernel with a hand-written init, following
# https://nick.zoic.org/art/boot-naked-linux/
#
# Downloads the Linux source tarball, compiles a small static init.c (with musl
# when available), embeds it as the kernel's built-in initramfs, and
# configures a minimal x86-64 build for KVM microVMs (virtio-mmio, no PCI).
#
# The kernel is app-agnostic: build-disk.sh builds the diskimage init mounts
# as /, holding whichever program from apps/ the VM should run. A successful
# build copies bzImage (for QEMU) and vmlinux (for Firecracker) into sys/,
# next to the diskimage.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
WORKDIR="${1:-$PWD/linux-src}"
KERNEL_DIR="$WORKDIR/linux"
SYS_DIR="$SCRIPT_DIR/sys"
JOBS="$(nproc)"
KERNEL_VERSION="7.2.11" # 6.18 also tested as it is LTS
KERNEL_TARBALL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VERSION%%.*}.x/linux-${KERNEL_VERSION}.tar.xz"
KERNEL_TARBALL="$SCRIPT_DIR/linux-${KERNEL_VERSION}.tar.xz"

log() { printf '\n>>> %s\n' "$*"; }

check_deps() {
    local missing=()
    for tool in curl tar xz make gcc bc flex bison qemu-system-x86_64 libelf-dev; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Missing required tools: ${missing[*]}" >&2
        echo "On Debian/Ubuntu: sudo apt install curl xz-utils build-essential bc flex bison qemu-system-x86 libelf-dev" >&2
        exit 1
    fi
}

fetch_kernel() {
    if [ -d "$KERNEL_DIR" ]; then
        log "Kernel source already present at $KERNEL_DIR, skipping download"
        return
    fi

    if [ ! -f "$KERNEL_TARBALL" ]; then
        log "Downloading Linux v$KERNEL_VERSION into $KERNEL_TARBALL"
        curl -fL -o "$KERNEL_TARBALL" "$KERNEL_TARBALL_URL"
    else
        log "Tarball already present at $KERNEL_TARBALL, skipping download"
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
    log "Generating tinyconfig for x86_64"
    make -C "$KERNEL_DIR" ARCH=x86_64 tinyconfig

    log "Enabling options needed for console, ELF init and virtio-mmio disk/net"
    "$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
        --enable BINFMT_ELF \
        --enable PRINTK \
        --enable PRINTK_TIME \
        --set-val LOG_BUF_SHIFT 14 \
        --enable DEVTMPFS \
        --enable DEVTMPFS_MOUNT \
        --enable TTY \
        --enable SERIAL_8250 \
        --enable SERIAL_8250_CONSOLE \
        --set-val SERIAL_8250_NR_UARTS 1 \
        --set-val SERIAL_8250_RUNTIME_UARTS 1 \
        --enable HYPERVISOR_GUEST \
        --enable PARAVIRT \
        --enable KVM_GUEST \
        --enable BLOCK \
        --enable VIRTIO_MENU \
        --enable VIRTIO \
        --enable VIRTIO_MMIO \
        --enable VIRTIO_MMIO_CMDLINE_DEVICES \
        --enable VIRTIO_BLK \
        --enable NET \
        --enable NETDEVICES \
        --enable VIRTIO_NET \
        --enable INET \
        --disable IPV6 \
        --enable PROC_FS \
        --enable EXT4_FS \
        --set-val LOCALVERSION '""' \
        --set-str DEFAULT_HOSTNAME minlin

    # Syscalls tinyconfig drops but ordinary dynamically linked programs
    # (glibc's ld.so, lighttpd's event loop) rely on.
    log "Enabling syscalls needed to run regular userspace programs"
    "$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
        --enable FUTEX \
        --enable EPOLL

    # Go programs (tailscaled) need eventfd for the runtime's network poller.
    # Tailscale's kernel-mode networking adds a TUN device, policy routing
    # rules and a local API on a Unix socket.
    log "Enabling eventfd, Unix sockets, TUN and policy routing for Tailscale"
    "$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
        --enable EVENTFD \
        --enable UNIX \
        --enable TUN \
        --enable IP_ADVANCED_ROUTER \
        --enable IP_MULTIPLE_TABLES

    # A Tailscale exit node forwards tailnet traffic out of eth0: init turns
    # on net.ipv4.ip_forward from the app's /etc/sysctl.conf (via
    # /proc/sys), and tailscaled masquerades the traffic with nftables, which
    # it programs over netlink without needing the nft or iptables tools.
    log "Enabling sysctls and nftables NAT for forwarding (Tailscale exit node)"
    "$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
        --enable PROC_SYSCTL \
        --enable NETFILTER \
        --enable NF_CONNTRACK \
        --enable NF_NAT \
        --enable NF_TABLES \
        --enable NF_TABLES_IPV4 \
        --enable NFT_CT \
        --enable NFT_NAT \
        --enable NFT_MASQ

    # sshd changes uid/gid (and supplementary groups) even when the login is
    # root, times out logins with setitimer, and runs an interactive session
    # on a pty (devpts, which init mounts on /dev/pts). glibc locks utmp
    # before recording a login there (as SQLite, for one, locks its files).
    log "Enabling uid/gid syscalls, interval timers, ptys and file locks for sshd"
    "$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
        --enable MULTIUSER \
        --enable POSIX_TIMERS \
        --enable UNIX98_PTYS \
        --enable FILE_LOCKING

    log "Embedding init as an uncompressed built-in initramfs"
    "$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
        --enable BLK_DEV_INITRD \
        --set-str INITRAMFS_SOURCE "$WORKDIR/initramfs.list" \
        --enable INITRAMFS_COMPRESSION_NONE \
        --disable RD_GZIP --disable RD_BZIP2 --disable RD_LZMA \
        --disable RD_XZ --disable RD_LZO --disable RD_LZ4 --disable RD_ZSTD

    # Firecracker's SendCtrlAltDel presses Ctrl-Alt-Del on its emulated
    # i8042 keyboard. The VT keyboard handler is what turns that key combo
    # into ctrl_alt_del(), which signals init (SIGINT, as init disables CAD)
    # to shut down cleanly. The VT is only there for its keyboard: the console
    # stays on ttyS0, and no mouse or serial-line input is needed.
    log "Enabling the i8042 keyboard and VT for Ctrl-Alt-Del shutdown"
    "$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
        --enable INPUT \
        --enable INPUT_KEYBOARD \
        --enable SERIO \
        --enable SERIO_I8042 \
        --enable SERIO_LIBPS2 \
        --enable KEYBOARD_ATKBD \
        --enable VT \
        --disable VT_CONSOLE --disable VT_HW_CONSOLE_BINDING \
        --disable CONSOLE_TRANSLATIONS \
        --disable INPUT_MOUSE --disable INPUT_MOUSEDEV \
        --disable SERIO_SERPORT

    # A KVM microVM has no PCI bus, VGA, microcode loading or partitioned
    # disks, so drop everything olddefconfig would pull in for them.
    log "Disabling hardware and features a microVM never uses"
    "$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
        --disable PCI \
        --disable VGA_CONSOLE \
        --disable HID_SUPPORT \
        --disable LEGACY_PTYS \
        --disable EARLY_PRINTK \
        --enable PROCESSOR_SELECT \
        --disable CPU_SUP_HYGON --disable CPU_SUP_CENTAUR --disable CPU_SUP_ZHAOXIN \
        --disable SWAP \
        --disable BLOCK_LEGACY_AUTOLOAD \
        --disable MQ_IOSCHED_DEADLINE --disable MQ_IOSCHED_KYBER \
        --enable PARTITION_ADVANCED --disable MSDOS_PARTITION --disable EFI_PARTITION \
        --disable INET_DIAG \
        --disable ETHTOOL_NETLINK --disable WIRELESS \
        --disable LEGACY_TIOCSTI \
        --disable INITRAMFS_PRESERVE_MTIME \
        --set-val INET_TABLE_PERTURB_ORDER 8 \
        --disable WLAN --disable ETHERNET \
        --disable PROC_PAGE_MONITOR --disable PROC_PID_ARCH_STATUS \
        --enable INIT_STACK_NONE --disable INIT_STACK_ALL_ZERO \
        --enable NO_HZ_IDLE --disable HZ_PERIODIC \
        --enable HZ_100 --disable HZ_250

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
