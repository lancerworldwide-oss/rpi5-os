#!/bin/bash
# Remove the QEMU user-static binary injected for chroot operations.

set -euo pipefail

: "${ROOT_MOUNT:?ROOT_MOUNT must be set}"

QEMU_PATH="${ROOT_MOUNT}/usr/bin/qemu-aarch64-static"
if [ -f "${QEMU_PATH}" ]; then
    sudo rm -f "${QEMU_PATH}"
fi
