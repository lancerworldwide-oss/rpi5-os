#!/bin/bash
# Mount a Raspberry Pi OS disk image for chroot operations.
# Sets LOOP_DEV, ROOT_MOUNT, BOOT_MOUNT, and MAPPER_BOOT, MAPPER_ROOT.

set -euo pipefail

IMAGE_FILE="${1:?image file required}"
MOUNT_BASE="${2:-/tmp/ddm-mount}"

cleanup_mounts() {
    local exit_code=$?
    if [ -n "${ROOT_MOUNT:-}" ] && mountpoint -q "${ROOT_MOUNT}/run" 2>/dev/null; then
        sudo umount "${ROOT_MOUNT}/run" || true
    fi
    if [ -n "${ROOT_MOUNT:-}" ] && mountpoint -q "${ROOT_MOUNT}/dev/pts" 2>/dev/null; then
        sudo umount "${ROOT_MOUNT}/dev/pts" || true
    fi
    if [ -n "${ROOT_MOUNT:-}" ] && mountpoint -q "${ROOT_MOUNT}/dev" 2>/dev/null; then
        sudo umount "${ROOT_MOUNT}/dev" || true
    fi
    if [ -n "${ROOT_MOUNT:-}" ] && mountpoint -q "${ROOT_MOUNT}/sys" 2>/dev/null; then
        sudo umount "${ROOT_MOUNT}/sys" || true
    fi
    if [ -n "${ROOT_MOUNT:-}" ] && mountpoint -q "${ROOT_MOUNT}/proc" 2>/dev/null; then
        sudo umount "${ROOT_MOUNT}/proc" || true
    fi
    if [ -n "${BOOT_MOUNT:-}" ] && mountpoint -q "${BOOT_MOUNT}" 2>/dev/null; then
        sudo umount "${BOOT_MOUNT}" || true
    fi
    if [ -n "${ROOT_MOUNT:-}" ] && mountpoint -q "${ROOT_MOUNT}" 2>/dev/null; then
        sudo umount "${ROOT_MOUNT}" || true
    fi
    if [ -n "${LOOP_DEV:-}" ]; then
        sudo kpartx -d "${LOOP_DEV}" 2>/dev/null || true
        sudo losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi
    exit "${exit_code}"
}

trap cleanup_mounts EXIT INT TERM

sudo mkdir -p "${MOUNT_BASE}/root"
ROOT_MOUNT="${MOUNT_BASE}/root"
BOOT_MOUNT="${ROOT_MOUNT}/boot/firmware"

LOOP_DEV="$(sudo losetup -Pf --show "${IMAGE_FILE}")"
sudo kpartx -av "${LOOP_DEV}" >/dev/null

LOOP_NAME="$(basename "${LOOP_DEV}")"
MAPPER_ROOT="/dev/mapper/${LOOP_NAME}p2"
MAPPER_BOOT="/dev/mapper/${LOOP_NAME}p1"

if [ ! -b "${MAPPER_ROOT}" ] || [ ! -b "${MAPPER_BOOT}" ]; then
    echo "ERROR: Expected Pi OS layout with p1 (boot) and p2 (root); got ${LOOP_NAME}" >&2
    exit 1
fi

sudo mount "${MAPPER_ROOT}" "${ROOT_MOUNT}"
sudo mkdir -p "${BOOT_MOUNT}"
sudo mount "${MAPPER_BOOT}" "${BOOT_MOUNT}"

sudo mount -t proc proc "${ROOT_MOUNT}/proc"
sudo mount -t sysfs sysfs "${ROOT_MOUNT}/sys"
sudo mount --bind /dev "${ROOT_MOUNT}/dev"
sudo mount -t devpts devpts "${ROOT_MOUNT}/dev/pts"
sudo mount --bind /run "${ROOT_MOUNT}/run"

# -L: dereference host symlink (qemu-aarch64-static -> qemu-aarch64) into a real binary.
sudo cp -L /usr/bin/qemu-aarch64-static "${ROOT_MOUNT}/usr/bin/qemu-aarch64-static"
sudo chmod +x "${ROOT_MOUNT}/usr/bin/qemu-aarch64-static"

export IMAGE_FILE MOUNT_BASE LOOP_DEV ROOT_MOUNT BOOT_MOUNT MAPPER_ROOT MAPPER_BOOT LOOP_NAME
