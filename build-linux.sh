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
#
# Usage: build-linux.sh [full] [workdir]
#
# "full" instead configures a stock x86_64_defconfig plus kvm_guest.config,
# adding the few options init and the apps rely on (virtio-mmio, devtmpfs, TUN,
# nftables NAT). Nothing is stripped out, so the kernel is several MB larger and
# needs more guest RAM than the minimal one (boot with MEM=64 or more). Its
# source tree lives in linux-full next to the minimal linux tree, so both can be
# kept, but it replaces the minimal kernel in sys/.

set -euo pipefail

FULL=0
if [ "${1:-}" = full ]; then
    FULL=1
    shift
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
WORKDIR="${1:-$PWD/linux-src}"
if [ "$FULL" = 1 ]; then
    KERNEL_DIR="$WORKDIR/linux-full"
else
    KERNEL_DIR="$WORKDIR/linux"
fi
SYS_DIR="$SCRIPT_DIR/sys"
JOBS="$(nproc)"
KERNEL_VERSION="7.3.1" # 6.18.60 also tested as it is LTS
# From sha256sums.asc beside the tarball on kernel.org. Change it with KERNEL_VERSION.
KERNEL_SHA256="fa595aad93734f829c963c2a90ef7c3673224fd7fdae7b49406e397cde2de231"
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
    log "Generating tinyconfig for x86_64"
    make -C "$KERNEL_DIR" ARCH=x86_64 tinyconfig

    # PANIC_TIMEOUT: the default of 0 leaves a panicked VM hanging forever, and
    # loglevel=0 hides the message. Rebooting ends the VM under any VMM.
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
        --enable SWAP \
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
        --set-val PANIC_TIMEOUT 1 \
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
    # The pre-auth process (sshd-auth) sandboxes itself with a seccomp-bpf
    # filter and drops the connection if the kernel can't install one.
    log "Enabling uid/gid syscalls, interval timers, ptys, file locks and seccomp for sshd"
    "$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
        --enable MULTIUSER \
        --enable POSIX_TIMERS \
        --enable UNIX98_PTYS \
        --enable FILE_LOCKING \
        --enable SECCOMP \
        --enable SECCOMP_FILTER

    # V8 (in lightpanda) hands memory back with madvise and treats a failed
    # call as fatal ("Check failed: 0 == ret."), so it aborts at startup
    # without it.
    "$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
        --enable ADVISE_SYSCALLS

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

configure_kernel_full() {
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
if [ "$FULL" = 1 ]; then
    configure_kernel_full
else
    configure_kernel
fi
build_kernel
install_kernel
#boot_qemu
