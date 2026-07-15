#!/bin/bash
# Generate a minimal NGSW Raspberry Pi 5 base image from upstream Pi OS Lite.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/scripts/lib"
DEFAULTS_FILE="${SCRIPT_DIR}/metadata/image-defaults.env"
PACKAGES_FILE="${SCRIPT_DIR}/packages.txt"

WORK_DIR="${WORK_DIR:-/workspace/.work}"
CACHE_DIR="${CACHE_DIR:-${WORK_DIR}}"
PROCESSING_DIR="${PROCESSING_DIR:-/tmp/ddm-processing}"
DIST_DIR="${DIST_DIR:-/workspace/dist}"
PADDING_SECTORS="${PADDING_SECTORS:-8192}"
MOUNT_BASE="${MOUNT_BASE:-/tmp/ddm-mount}"

log() {
    echo "[ddm] $*"
}

die() {
    echo "[ddm] ERROR: $*" >&2
    exit 1
}

require_root_tools() {
    command -v losetup >/dev/null || die "losetup not found"
    command -v kpartx >/dev/null || die "kpartx not found"
    command -v chroot >/dev/null || die "chroot not found"
}

load_defaults() {
    if [ -f "${DEFAULTS_FILE}" ]; then
        # shellcheck disable=SC1090
        source "${DEFAULTS_FILE}"
    fi
}

validate_sha256() {
    local file="$1"
    local expected="$2"
    local actual
    actual="$(sha256sum "${file}" | awk '{print $1}')"
    if [ "${actual}" != "${expected}" ]; then
        die "SHA256 mismatch for ${file}: expected ${expected}, got ${actual}"
    fi
    log "SHA256 verified for ${file}"
}

download_source() {
    local url="$1"
    local dest="$2"
    local checksum="${3:-}"

    if [ -f "${dest}" ]; then
        if [ -n "${checksum}" ]; then
            validate_sha256 "${dest}" "${checksum}"
            log "Using cached download: ${dest}"
            return
        fi
        log "Using cached download (no checksum configured): ${dest}"
        return
    fi

    log "Downloading ${url}"
    mkdir -p "$(dirname "${dest}")"
    curl -fL --retry 3 -o "${dest}" "${url}"

    if [ -n "${checksum}" ]; then
        validate_sha256 "${dest}" "${checksum}"
    fi
}

decompress_if_needed() {
    local src="$1"
    local dest="$2"

    mkdir -p "$(dirname "${dest}")"

    if [ -f "${dest}" ]; then
        log "Using existing working copy: ${dest}"
        return
    fi

    rm -rf "${dest}"

    case "${src}" in
        *.xz)
            log "Decompressing ${src}"
            xz -dc "${src}" > "${dest}"
            ;;
        *)
            cp "${src}" "${dest}"
            ;;
    esac
}

read_packages() {
    local packages=()
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line%%#*}"
        line="${line//$'\r'/}"
        line="$(echo "${line}" | xargs)"
        [ -n "${line}" ] && packages+=("${line}")
    done < "${PACKAGES_FILE}"
    printf '%s\n' "${packages[@]}"
}

purge_packages_in_chroot() {
    local packages
    mapfile -t packages < <(read_packages)

    if [ "${#packages[@]}" -eq 0 ]; then
        log "No packages listed in ${PACKAGES_FILE}; skipping purge"
        return
    fi

    log "Removing ${#packages[@]} packages from image"
    bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c "
        set -uo pipefail
        export DEBIAN_FRONTEND=noninteractive
        for pkg in ${packages[*]}; do
            if dpkg-query -W -f='\${Status}' \"\${pkg}\" 2>/dev/null | grep -q 'install ok installed'; then
                echo \"Purging \${pkg}\"
                apt-get purge -y \"\${pkg}\" || echo \"WARN: failed to purge \${pkg}\"
            else
                echo \"Skipping \${pkg} (not installed)\"
            fi
        done
        apt-get autoremove -y || true
    "
}

generate_package_manifest() {
    local release_tag="$1"
    local manifest="${DIST_DIR}/${release_tag}-ngsw-minimal.packages.txt"

    mkdir -p "${DIST_DIR}"
    log "Writing installed package manifest to ${manifest}"
    bash "${LIB_DIR}/chroot_exec.sh" dpkg-query -W \
        -f='${Package}\t${Version}\t${Architecture}\n' \
        | LC_ALL=C sort > "${manifest}"
}

minimize_in_chroot() {
    log "Minimizing image: clearing caches and truncating log files"
    bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c "
        set -uo pipefail
        apt-get clean || true
        rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/*
        if [ -d /var/log ]; then
            find /var/log -type f -print0 | xargs -0 -r truncate -s 0
        fi
    "
}

minimize_unmounted_root() {
    log "Checking root filesystem"
    sudo e2fsck -fy "${MAPPER_ROOT}"

    if command -v zerofree >/dev/null; then
        log "Zeroing free space with zerofree"
        sudo zerofree -v "${MAPPER_ROOT}" || log "zerofree returned non-zero; continuing"
    else
        log "zerofree not available; skipping zero-fill"
    fi
}

finalize_before_shrink() {
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
    if mountpoint -q "${BOOT_MOUNT}" 2>/dev/null; then
        sudo umount "${BOOT_MOUNT}"
    fi
    if mountpoint -q "${ROOT_MOUNT}" 2>/dev/null; then
        sudo umount "${ROOT_MOUNT}"
    fi

    minimize_unmounted_root

    sudo kpartx -d "${LOOP_DEV}" 2>/dev/null || true
    sudo losetup -d "${LOOP_DEV}" 2>/dev/null || true
    trap - EXIT INT TERM
}

shrink_image() {
    local image="$1"
    local loop_dev mapper_root fs_blocks fs_block_size fs_bytes part_start part_end truncate_bytes

    log "Shrinking root filesystem"
    loop_dev="$(sudo losetup -Pf --show "${image}")"
    sudo kpartx -av "${loop_dev}" >/dev/null
    mapper_root="/dev/mapper/$(basename "${loop_dev}")p2"

    sudo e2fsck -fy "${mapper_root}"
    sudo resize2fs -M "${mapper_root}"

    fs_blocks="$(sudo tune2fs -l "${mapper_root}" | awk '/Block count:/ {print $3}')"
    fs_block_size="$(sudo tune2fs -l "${mapper_root}" | awk '/Block size:/ {print $3}')"
    fs_bytes=$((fs_blocks * fs_block_size))

    part_start="$(
        sudo parted -s "${loop_dev}" unit B print | awk '/^ 2 / {gsub(/B/, "", $2); print $2}'
    )"
    part_end=$((part_start + fs_bytes + PADDING_SECTORS * 512))

    log "Resizing partition 2 to end at ${part_end} bytes"
    echo Yes | sudo parted ---pretend-input-tty "${loop_dev}" unit B resizepart 2 "${part_end}"

    truncate_bytes=$((part_end + 512))

    sudo kpartx -d "${loop_dev}"
    sudo losetup -d "${loop_dev}"

    log "Truncating image to ${truncate_bytes} bytes"
    sudo truncate -s "${truncate_bytes}" "${image}"
}

package_artifact() {
    local image="$1"
    local artifact_name="$2"
    local tarball="${DIST_DIR}/${artifact_name}.tar.gz"

    mkdir -p "${DIST_DIR}"
    log "Creating ${tarball}"
    tar -C "$(dirname "${image}")" -czf "${tarball}" "$(basename "${image}")"
    sha256sum "${tarball}" > "${tarball}.sha256"
    log "Wrote ${tarball}"
    log "Wrote ${tarball}.sha256"
}

main() {
    require_root_tools
    load_defaults

    # Normalize line endings when bind-mounted from Windows hosts.
    sed -i 's/\r$//' "${PACKAGES_FILE}" 2>/dev/null || true

    # shellcheck disable=SC1091
    source "${LIB_DIR}/setup_binfmt.sh"

    local source_url="${RPI_SOURCE_IMG:-}"
    local source_sha="${RPI_SOURCE_IMG_SHA256:-}"

    if [ -z "${source_url}" ]; then
        die "RPI_SOURCE_IMG is not set and no default is available"
    fi

    mkdir -p "${CACHE_DIR}" "${PROCESSING_DIR}" "${DIST_DIR}"

    local download_name
    download_name="$(basename "${source_url}")"
    local download_path="${CACHE_DIR}/${download_name}"
    local working_img="${PROCESSING_DIR}/working.img"
    local release_tag
    release_tag="$(basename "${download_name}" .img.xz)"
    release_tag="${release_tag%.img}"

    log "Phase 1: Download source image"
    download_source "${source_url}" "${download_path}" "${source_sha}"

    log "Phase 2: Prepare working copy"
    decompress_if_needed "${download_path}" "${working_img}"

    log "Phase 3: Mount image and chroot"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/mount_image.sh" "${working_img}" "${MOUNT_BASE}"

    log "Phase 4: Purge packages"
    purge_packages_in_chroot

    log "Phase 4b: Record remaining installed packages on host"
    generate_package_manifest "${release_tag}"

    log "Phase 4c: Minimize caches and logs"
    minimize_in_chroot

    log "Phase 4d: Remove injected QEMU binary from image"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/remove_qemu_static.sh"

    log "Phase 5: Unmount, check filesystem, and zero free space"
    finalize_before_shrink

    log "Phase 6: Shrink and truncate image"
    shrink_image "${working_img}"

    local final_name="${release_tag}-ngsw-minimal.img"
    local final_path="${PROCESSING_DIR}/${final_name}"
    mv "${working_img}" "${final_path}"

    log "Phase 7: Package artifact"
    package_artifact "${final_path}" "${final_name}"

    log "Done: ${DIST_DIR}/${final_name}.tar.gz"
}

main "$@"
