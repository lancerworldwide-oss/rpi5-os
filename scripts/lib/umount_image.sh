#!/bin/bash
# Unmount a previously mounted Raspberry Pi OS disk image.

set -euo pipefail

: "${ROOT_MOUNT:?ROOT_MOUNT must be set}"
: "${LOOP_DEV:?LOOP_DEV must be set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/remove_qemu_static.sh"

if mountpoint -q "${ROOT_MOUNT}/run" 2>/dev/null; then
    sudo umount "${ROOT_MOUNT}/run"
fi
if mountpoint -q "${ROOT_MOUNT}/dev/pts" 2>/dev/null; then
    sudo umount "${ROOT_MOUNT}/dev/pts"
fi
if mountpoint -q "${ROOT_MOUNT}/dev" 2>/dev/null; then
    sudo umount "${ROOT_MOUNT}/dev"
fi
if mountpoint -q "${ROOT_MOUNT}/sys" 2>/dev/null; then
    sudo umount "${ROOT_MOUNT}/sys"
fi
if mountpoint -q "${ROOT_MOUNT}/proc" 2>/dev/null; then
    sudo umount "${ROOT_MOUNT}/proc"
fi
if [ -n "${BOOT_MOUNT:-}" ] && mountpoint -q "${BOOT_MOUNT}" 2>/dev/null; then
    sudo umount "${BOOT_MOUNT}"
fi
if mountpoint -q "${ROOT_MOUNT}" 2>/dev/null; then
    sudo umount "${ROOT_MOUNT}"
fi

sudo kpartx -d "${LOOP_DEV}" 2>/dev/null || true
sudo losetup -d "${LOOP_DEV}" 2>/dev/null || true

trap - EXIT INT TERM