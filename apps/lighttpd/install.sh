# Sourced by build-disk.sh: installs the host's lighttpd and the modules
# rootfs/etc/lighttpd/lighttpd.conf loads.

require lighttpd

install_binary "$(command -v lighttpd)"
# Modules lighttpd.conf loads, plus mod_h2 which lighttpd loads by default.
moddir="$(dirname "$(find /usr/lib -name mod_h2.so -path '*lighttpd*' -print -quit)")"
for mod in h2 accesslog status; do
    install_binary "$moddir/mod_$mod.so"
done
