# Sourced by build-disk.sh: installs the host's node, its shared libraries,
# and the JavaScript files Debian/Ubuntu's build loads at startup.

require node nodejs

install_binary "$(command -v node)"
# Not linked in, so ldd can't see them. Found with strace on the host.
for dep in acorn acorn-walk cjs-module-lexer minimatch undici; do
    cp -rL --parents "/usr/share/nodejs/$dep" "$ROOTFS"
done

DISK_SIZE=256M
