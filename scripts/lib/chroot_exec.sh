#!/bin/bash
# Execute a command inside a mounted Pi OS root filesystem via QEMU.

set -euo pipefail

: "${ROOT_MOUNT:?ROOT_MOUNT must be set}"

if [ $# -eq 0 ]; then
    echo "Usage: $0 <command> [args...]" >&2
    exit 1
fi

QEMU="${ROOT_MOUNT}/usr/bin/qemu-aarch64-static"
if [ ! -x "${QEMU}" ]; then
    echo "ERROR: ${QEMU} not found; mount_image.sh must run first" >&2
    exit 1
fi

sudo chroot "${ROOT_MOUNT}" "$@"
