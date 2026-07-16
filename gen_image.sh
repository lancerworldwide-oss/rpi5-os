#!/bin/bash
# Generate a minimal NGSW Raspberry Pi 5 kiosk base image from upstream Pi OS desktop.
# Strips the Pi Desktop shell, keeps Wayland/GPU/VAAPI, installs cage + Thorium.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/scripts/lib"
DEFAULTS_FILE="${SCRIPT_DIR}/metadata/image-defaults.env"
PACKAGES_FILE="${SCRIPT_DIR}/packages.txt"
WAYLAND_PACKAGES_FILE="${SCRIPT_DIR}/wayland-packages.txt"

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
    command -v xz >/dev/null || die "xz not found"
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

read_package_file() {
    local file="$1"
    local packages=()
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line%%#*}"
        line="${line//$'\r'/}"
        line="$(echo "${line}" | xargs)"
        [ -n "${line}" ] && packages+=("${line}")
    done < "${file}"
    printf '%s\n' "${packages[@]}"
}

read_packages() {
    read_package_file "${PACKAGES_FILE}"
}

prepare_chroot_apt() {
    # DNS for apt inside the guest; must run before any network apt operations.
    sudo cp /etc/resolv.conf "${ROOT_MOUNT}/etc/resolv.conf"
}

purge_packages_in_chroot() {
    local packages
    mapfile -t packages < <(read_packages)

    if [ "${#packages[@]}" -eq 0 ]; then
        log "No packages listed in ${PACKAGES_FILE}; skipping purge"
        return
    fi

    # Purge before upgrade so bulky desktop apps (Chromium, Firefox, etc.)
    # are not upgraded into a nearly-full rootfs. One apt-get transaction under
    # QEMU is far faster than N per-package purges.
    log "Removing ${#packages[@]} packages from image"
    bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c "
        set -uo pipefail
        export DEBIAN_FRONTEND=noninteractive
        installed=()
        for pkg in ${packages[*]}; do
            if dpkg-query -W -f='\${Status}' \"\${pkg}\" 2>/dev/null | grep -q 'install ok installed'; then
                installed+=(\"\${pkg}\")
            else
                echo \"Skipping \${pkg} (not installed)\"
            fi
        done
        if [ \${#installed[@]} -gt 0 ]; then
            echo \"Purging \${#installed[@]} packages in one transaction\"
            apt-get purge -y \"\${installed[@]}\" || echo \"WARN: batch purge reported errors\"
        fi
        apt-get autoremove -y || true
        apt-get clean || true
        rm -rf /var/cache/apt/archives/partial/*
    "
}

upgrade_packages_in_chroot() {
    log "Updating package indexes and upgrading installed packages"
    bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c "
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        rm -rf /var/lib/apt/lists/*
        apt-get update
        apt-get upgrade -y \
            -o Dpkg::Options::=\"--force-confdef\" \
            -o Dpkg::Options::=\"--force-confold\"
    "
}

ensure_wayland_stack_in_chroot() {
    local packages
    mapfile -t packages < <(read_package_file "${WAYLAND_PACKAGES_FILE}")

    if [ "${#packages[@]}" -eq 0 ]; then
        die "No packages listed in ${WAYLAND_PACKAGES_FILE}"
    fi

    log "Ensuring Wayland/kiosk stack (${#packages[@]} packages)"
    bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c "
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends ${packages[*]} \
            -o Dpkg::Options::=\"--force-confdef\" \
            -o Dpkg::Options::=\"--force-confold\"
    "
}

install_thorium_in_chroot() {
    local url="$1"
    local checksum="${2:-}"
    local deb_name deb_path

    [ -n "${url}" ] || die "THORIUM_DEB_URL is not set and no default is available"

    deb_name="$(basename "${url}")"
    deb_path="${CACHE_DIR}/${deb_name}"

    log "Downloading Thorium from ${url}"
    download_source "${url}" "${deb_path}" "${checksum}"

    log "Installing Thorium into image"
    sudo cp "${deb_path}" "${ROOT_MOUNT}/tmp/thorium.deb"
    bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c "
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends /tmp/thorium.deb \
            -o Dpkg::Options::=\"--force-confdef\" \
            -o Dpkg::Options::=\"--force-confold\"
        rm -f /tmp/thorium.deb
    "
}

# Purge thorium_shell only when a dedicated package owns it (never rm files).
maybe_purge_thorium_shell() {
    local owners owner pkg purge_pkgs=()

    log "Checking whether thorium_shell can be removed via apt"
    owners="$(
        bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c "
            set -uo pipefail
            path=''
            for candidate in /opt/chromium.org/thorium/thorium_shell /usr/bin/thorium_shell; do
                if [ -e \"\${candidate}\" ]; then
                    path=\"\${candidate}\"
                    break
                fi
            done
            if [ -z \"\${path}\" ]; then
                echo 'NOT_FOUND'
                exit 0
            fi
            # dpkg -S prints 'pkg: path' or 'pkg:arch: path'.
            dpkg-query -S \"\${path}\" 2>/dev/null | awk -F: '{print \$1}' | sort -u
        "
    )" || true

    if [ -z "${owners}" ] || [ "${owners}" = "NOT_FOUND" ]; then
        log "thorium_shell not present; nothing to purge"
        return
    fi

    while IFS= read -r owner || [ -n "${owner}" ]; do
        [ -n "${owner}" ] || continue
        pkg="${owner%%:*}"
        if [ "${pkg}" = "thorium-browser" ]; then
            log "thorium_shell owned by thorium-browser; skipping (apt cannot remove a single file)"
            continue
        fi
        purge_pkgs+=("${pkg}")
    done <<< "${owners}"

    if [ "${#purge_pkgs[@]}" -eq 0 ]; then
        return
    fi

    log "Purging dedicated thorium_shell package(s): ${purge_pkgs[*]}"
    bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c "
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        apt-get purge -y ${purge_pkgs[*]}
        apt-get autoremove -y || true
        apt-get clean || true
    "
}

# Restore Trixie first-boot root expand: cmdline "resize" + initramfs resize_early
# + rpi-resize.service (systemd-growfs-root). Package may be dropped by autoremove.
ensure_rootfs_resize() {
    log "Ensuring first-boot rootfs resize wiring"
    bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c "
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive

        if ! dpkg-query -W -f='\${Status}' raspberrypi-sys-mods 2>/dev/null | grep -q 'install ok installed'; then
            echo 'ERROR: raspberrypi-sys-mods is not installed' >&2
            exit 1
        fi

        if [ ! -x /usr/share/initramfs-tools/scripts/local-premount/resize_early ]; then
            echo 'ERROR: resize_early initramfs hook missing' >&2
            exit 1
        fi

        cmdline=/boot/firmware/cmdline.txt
        if [ ! -f \"\${cmdline}\" ]; then
            echo \"ERROR: \${cmdline} missing\" >&2
            exit 1
        fi
        # resize_early matches a leading-space token: ' resize' in /proc/cmdline.
        if ! grep -Eq '(^|[[:space:]])resize([[:space:]]|\$)' \"\${cmdline}\"; then
            sed -i 's/[[:space:]]*\$/ resize/' \"\${cmdline}\"
        fi

        mkdir -p /etc/systemd/system/sysinit.target.wants
        if [ -f /usr/lib/systemd/system/rpi-resize.service ]; then
            ln -sfn /usr/lib/systemd/system/rpi-resize.service \
                /etc/systemd/system/sysinit.target.wants/rpi-resize.service
        else
            echo 'ERROR: rpi-resize.service unit missing' >&2
            exit 1
        fi

        # Leave /etc/machine-id as uninitialized for ConditionFirstBoot=yes.

        update-initramfs -u
    "
}

# Retarget boot to multi-user console and create a usable login account.
# Upstream desktop default.target/graphical leftovers remain after LightDM/piwiz purge.
configure_console_boot() {
    log "Configuring multi-user console boot and rpi login user"
    bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c "
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive

        # Prefer multi-user.target (console); do not enable any display manager.
        # systemctl may fail in chroot without a bus; fall back to a direct symlink.
        if ! systemctl set-default multi-user.target 2>/dev/null; then
            for candidate in \
                /lib/systemd/system/multi-user.target \
                /usr/lib/systemd/system/multi-user.target
            do
                if [ -e \"\${candidate}\" ]; then
                    ln -sfn \"\${candidate}\" /etc/systemd/system/default.target
                    break
                fi
            done
        fi
        readlink -f /etc/systemd/system/default.target | grep -q '/multi-user\\.target$'

        rm -f /etc/systemd/system/display-manager.service
        rm -f /etc/xdg/autostart/piwiz.desktop

        # Upstream first-boot wizard autologin blocks a normal console getty.
        rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
        if [ -d /etc/systemd/system/getty@tty1.service.d ]; then
            rmdir /etc/systemd/system/getty@tty1.service.d 2>/dev/null || true
        fi

        # Statically enable getty on tty1. Without this, the boot VT relies on
        # logind autovt spawn and can sit at multi-user.target with no login:
        # prompt while secondary VTs (Ctrl+Alt+F2) still work on demand.
        mkdir -p /etc/systemd/system/getty.target.wants
        ln -sfn /usr/lib/systemd/system/getty@.service \
            /etc/systemd/system/getty.target.wants/getty@tty1.service

        if id rpi-first-boot-wizard >/dev/null 2>&1; then
            userdel -r rpi-first-boot-wizard 2>/dev/null || userdel rpi-first-boot-wizard || true
        fi

        # Purge residual plymouth (theme meta may leave package in rc + SysV links).
        if dpkg-query -W -f='\${Status}' plymouth 2>/dev/null | grep -qE 'install ok installed|deinstall ok config-files'; then
            apt-get purge -y plymouth || dpkg --purge plymouth || true
        fi
        rm -f /etc/rc2.d/*plymouth* /etc/rcS.d/*plymouth* /etc/rc0.d/*plymouth* /etc/rc6.d/*plymouth* \
            /etc/init.d/plymouth /etc/init.d/plymouth-log 2>/dev/null || true

        # Ensure sudo is present for the console admin account.
        if ! dpkg-query -W -f='\${Status}' sudo 2>/dev/null | grep -q 'install ok installed'; then
            apt-get update
            apt-get install -y --no-install-recommends sudo
        fi

        if ! id rpi >/dev/null 2>&1; then
            useradd -m -s /bin/bash rpi
        else
            usermod -s /bin/bash rpi
        fi
        echo 'rpi:rpi' | chpasswd
        usermod -aG sudo rpi
    "
}

generate_package_manifest() {
    local release_tag="$1"
    local manifest="${DIST_DIR}/${release_tag}-ngsw-minimal.packages.txt"

    mkdir -p "${DIST_DIR}"
    log "Writing installed package manifest to ${manifest}"
    # Only packages with status "install ok installed" (skip residual config-files).
    bash "${LIB_DIR}/chroot_exec.sh" dpkg-query -W \
        -f='${db:Status-Abbrev}\t${Package}\t${Version}\t${Architecture}\n' \
        | awk -F'\t' '$1 ~ /^ii/ { print $2 "\t" $3 "\t" $4 }' \
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

# Compact extents toward the start of the FS so resize2fs -M can reclaim free space.
defrag_rootfs() {
    if ! command -v e4defrag >/dev/null; then
        log "e4defrag not available; skipping rootfs defrag"
        return
    fi
    if ! mountpoint -q "${ROOT_MOUNT}" 2>/dev/null; then
        log "Rootfs not mounted; skipping e4defrag"
        return
    fi
    log "Defragmenting rootfs with e4defrag to compact used blocks before shrink"
    sudo e4defrag -v "${ROOT_MOUNT}" || log "e4defrag returned non-zero; continuing"
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
    defrag_rootfs

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
    local dest_img="${DIST_DIR}/${artifact_name}"
    local dest_xz="${dest_img}.xz"

    mkdir -p "${DIST_DIR}"
    rm -f "${dest_img}" "${dest_xz}" "${dest_img}.sha256" "${dest_xz}.sha256"

    log "Compressing ${image} -> ${dest_xz}"
    xz -T0 -c "${image}" > "${dest_xz}"
    rm -f "${image}"

    sha256sum "${dest_xz}" > "${dest_xz}.sha256"
    log "Wrote ${dest_xz}"
    log "Wrote ${dest_xz}.sha256"
}

main() {
    require_root_tools
    load_defaults

    # Normalize line endings when bind-mounted from Windows hosts.
    sed -i 's/\r$//' "${PACKAGES_FILE}" "${WAYLAND_PACKAGES_FILE}" 2>/dev/null || true

    # shellcheck disable=SC1091
    source "${LIB_DIR}/setup_binfmt.sh"

    local source_url="${RPI_SOURCE_IMG:-}"
    local source_sha="${RPI_SOURCE_IMG_SHA256:-}"
    local thorium_url="${THORIUM_DEB_URL:-}"
    local thorium_sha="${THORIUM_DEB_SHA256:-}"

    if [ -z "${source_url}" ]; then
        die "RPI_SOURCE_IMG is not set and no default is available"
    fi
    if [ -z "${thorium_url}" ]; then
        die "THORIUM_DEB_URL is not set and no default is available"
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

    log "Phase 3b: Smoke-test ARM64 chroot via QEMU binfmt"
    if ! bash "${LIB_DIR}/chroot_exec.sh" /bin/true; then
        die "chroot smoke test failed (binfmt/QEMU aarch64 not working); see setup_binfmt.sh"
    fi

    log "Phase 4: Purge desktop shell and addon packages"
    prepare_chroot_apt
    purge_packages_in_chroot

    log "Phase 5: Update and upgrade remaining packages"
    upgrade_packages_in_chroot

    log "Phase 5b: Ensure Wayland/kiosk stack (labwc, cage, GPU/VAAPI)"
    ensure_wayland_stack_in_chroot

    log "Phase 5c: Install Thorium browser"
    install_thorium_in_chroot "${thorium_url}" "${thorium_sha}"

    log "Phase 5c2: Optionally purge dedicated thorium_shell package"
    maybe_purge_thorium_shell

    log "Phase 5c3: Configure multi-user console boot and rpi user"
    configure_console_boot

    log "Phase 5c4: Ensure first-boot rootfs resize wiring"
    ensure_rootfs_resize

    log "Phase 5d: Record remaining installed packages on host"
    generate_package_manifest "${release_tag}"

    log "Phase 5e: Minimize caches and logs"
    minimize_in_chroot

    log "Phase 5f: Remove injected QEMU binary from image"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/remove_qemu_static.sh"

    log "Phase 6: Defrag, unmount, check filesystem, and zero free space"
    finalize_before_shrink

    log "Phase 7: Shrink and truncate image"
    shrink_image "${working_img}"

    local final_name="${release_tag}-ngsw-minimal.img"
    local final_path="${PROCESSING_DIR}/${final_name}"
    mv "${working_img}" "${final_path}"

    log "Phase 8: Publish compressed artifact"
    package_artifact "${final_path}" "${final_name}"

    log "Done: ${DIST_DIR}/${final_name}.xz"
}

main "$@"
