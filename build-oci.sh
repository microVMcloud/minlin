#!/usr/bin/env bash
#
# Build sys/diskimage from a container image, with no Docker needed:
#
#   ./build-oci.sh <image> [workdir]
#   ./build-oci.sh caddy:latest
#   OCI_ENV="DNSMASQ_USER=root" ./build-oci.sh pihole/pihole
#
# A shorthand for IMAGE=<image> ./build-disk.sh oci. The OCI_* variables
# (OCI_ENV, OCI_CMD, OCI_ACTION, OCI_PLATFORM) are described in
# apps/oci/install.sh and apply here too.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 <image> [workdir]   e.g. $0 pihole/pihole" >&2
    exit 1
fi

IMAGE="$1" exec "$SCRIPT_DIR/build-disk.sh" oci "${@:2}"
