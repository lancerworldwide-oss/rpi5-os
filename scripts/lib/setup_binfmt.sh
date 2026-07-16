#!/bin/bash
# Register QEMU ARM64 binfmt handlers for chroot child process execution.

set -euo pipefail

die() {
    echo "[ddm] ERROR: $*" >&2
    exit 1
}

BINFMT_ENTRY="/proc/sys/fs/binfmt_misc/qemu-aarch64"
BINFMT_REGISTER="/proc/sys/fs/binfmt_misc/register"
SYSTEMD_BINFMT="/usr/lib/systemd/systemd-binfmt"

ensure_binfmt_mounted() {
    if [ ! -f "${BINFMT_REGISTER}" ]; then
        sudo mkdir -p /proc/sys/fs/binfmt_misc
        sudo mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc \
            || die "failed to mount binfmt_misc (is the container privileged?)"
    fi
    [ -f "${BINFMT_REGISTER}" ] || die "binfmt_misc register node missing after mount"
    sudo test -w "${BINFMT_REGISTER}" || die "binfmt_misc register is not writable (need privileged container)"
}

entry_has_f_flag() {
    [ -f "${BINFMT_ENTRY}" ] || return 1
    grep -q '^enabled$' "${BINFMT_ENTRY}" || return 1
    # flags line looks like: flags: CF  or  flags: F
    grep -E '^flags:.*F' "${BINFMT_ENTRY}" >/dev/null
}

unregister_qemu_aarch64() {
    if [ -f "${BINFMT_ENTRY}" ]; then
        echo -1 | sudo tee "${BINFMT_ENTRY}" >/dev/null || true
    fi
}

register_qemu_aarch64() {
    local interpreter
    local host_qemu

    host_qemu="/usr/bin/qemu-aarch64-static"
    if [ ! -e "${host_qemu}" ]; then
        host_qemu="/usr/bin/qemu-aarch64"
    fi
    [ -e "${host_qemu}" ] || die "qemu-aarch64 interpreter not found on host (install qemu-user-static)"

    interpreter="$(readlink -f "${host_qemu}")"
    [ -x "${interpreter}" ] || die "qemu interpreter is not executable: ${interpreter}"

    # Prefer Debian's packaged systemd-binfmt rules when available.
    if [ -x "${SYSTEMD_BINFMT}" ]; then
        sudo "${SYSTEMD_BINFMT}" 2>/dev/null || true
    fi

    if entry_has_f_flag; then
        return 0
    fi

    # Replace missing/non-F registrations with an explicit CF rule so chroot works.
    unregister_qemu_aarch64

    printf '%s\n' \
        ":qemu-aarch64:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\xb7\\x00:\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff:${interpreter}:CF" \
        | sudo tee "${BINFMT_REGISTER}" >/dev/null \
        || die "failed to register qemu-aarch64 binfmt"

    entry_has_f_flag || die "qemu-aarch64 binfmt missing, disabled, or lacks F flag after registration"
}

ensure_binfmt_mounted
register_qemu_aarch64
