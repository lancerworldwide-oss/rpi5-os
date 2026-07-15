#!/bin/bash
# Verify a generated minimal image artifact.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${SCRIPT_DIR}/scripts/lib"
PACKAGES_FILE="${SCRIPT_DIR}/packages.txt"
DIST_DIR="${DIST_DIR:-/workspace/dist}"
MOUNT_BASE="${MOUNT_BASE:-/tmp/ddm-verify-mount}"

log() {
    echo "[verify] $*"
}

die() {
    echo "[verify] FAIL: $*" >&2
    exit 1
}

pass() {
    echo "[verify] PASS: $*"
}

find_latest_artifact() {
    local latest
    latest="$(ls -1t "${DIST_DIR}"/*.tar.gz 2>/dev/null | head -n 1 || true)"
    [ -n "${latest}" ] || die "No artifacts found in ${DIST_DIR}"
    printf '%s\n' "${latest}"
}

read_packages() {
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line%%#*}"
        line="${line//$'\r'/}"
        line="$(echo "${line}" | xargs)"
        [ -n "${line}" ] && printf '%s\n' "${line}"
    done < "${PACKAGES_FILE}"
}

package_installed_in_chroot() {
    local pkg="$1"
    bash "${LIB_DIR}/chroot_exec.sh" dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null \
        | grep -q 'install ok installed'
}

manifest_path_for_artifact() {
    local artifact="$1"
    printf '%s/%s.packages.txt\n' "${DIST_DIR}" "$(basename "${artifact}" .img.tar.gz)"
}

check_qemu_absent_from_image() {
    local img_path="$1"
    local loop_dev loop_name mapper_root check_mount

    loop_dev="$(sudo losetup -Pf --show "${img_path}")"
    sudo kpartx -av "${loop_dev}" >/dev/null
    loop_name="$(basename "${loop_dev}")"
    mapper_root="/dev/mapper/${loop_name}p2"
    check_mount="$(mktemp -d)"

    sudo mount "${mapper_root}" "${check_mount}"
    if [ -f "${check_mount}/usr/bin/qemu-aarch64-static" ]; then
        sudo umount "${check_mount}"
        sudo kpartx -d "${loop_dev}" 2>/dev/null || true
        sudo losetup -d "${loop_dev}" 2>/dev/null || true
        rmdir "${check_mount}"
        die "qemu-aarch64-static present in image"
    fi
    sudo umount "${check_mount}"
    sudo kpartx -d "${loop_dev}" 2>/dev/null || true
    sudo losetup -d "${loop_dev}" 2>/dev/null || true
    rmdir "${check_mount}"
    pass "qemu-aarch64-static absent from image"
}

main() {
    local artifact="${1:-}"
    local tmp_dir img_path failures=0

    # shellcheck disable=SC1091
    source "${LIB_DIR}/setup_binfmt.sh"

    if [ -z "${artifact}" ]; then
        artifact="$(find_latest_artifact)"
    fi
    [ -f "${artifact}" ] || die "Artifact not found: ${artifact}"

    log "Verifying ${artifact}"

    if [ -f "${artifact}.sha256" ]; then
        sha256sum -c "${artifact}.sha256" || die "Artifact checksum mismatch"
        pass "artifact SHA256"
    fi

    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"' EXIT

    tar -xzf "${artifact}" -C "${tmp_dir}"
    img_path="$(find "${tmp_dir}" -maxdepth 1 -name '*.img' -print -quit)"
    [ -n "${img_path}" ] || die "No .img file inside ${artifact}"

    check_qemu_absent_from_image "${img_path}"

    local manifest
    manifest="$(manifest_path_for_artifact "${artifact}")"
    if [ -s "${manifest}" ]; then
        pass "package manifest present: ${manifest}"
    else
        die "Package manifest missing or empty: ${manifest}"
    fi

    # shellcheck disable=SC1091
    source "${LIB_DIR}/mount_image.sh" "${img_path}" "${MOUNT_BASE}"

    if sudo e2fsck -fn "${MAPPER_ROOT}" >/dev/null 2>&1; then
        pass "root filesystem e2fsck"
    else
        die "root filesystem e2fsck failed"
    fi

    while IFS= read -r pkg; do
        pkg="${pkg//$'\r'/}"
        if package_installed_in_chroot "${pkg}"; then
            log "Package still installed: ${pkg}"
            failures=$((failures + 1))
        fi
    done < <(read_packages)

    if [ "${failures}" -eq 0 ]; then
        pass "removed packages absent from image"
    else
        die "${failures} packages from packages.txt are still installed"
    fi

    for pkg in binutils-aarch64-linux-gnu python3.13 perl; do
        if package_installed_in_chroot "${pkg}"; then
            die "required removal still installed: ${pkg}"
        fi
    done
    pass "binutils-aarch64-linux-gnu, python3.13, and perl absent from image"

    # shellcheck disable=SC1091
    source "${LIB_DIR}/umount_image.sh"
    trap - EXIT

    pass "verification complete for ${artifact}"
}

main "$@"
