#!/bin/bash
# Verify a generated minimal kiosk Wayland image artifact.

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
    latest="$(ls -1t "${DIST_DIR}"/*-ngsw-minimal.img.xz 2>/dev/null | head -n 1 || true)"
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

command_in_chroot() {
    local cmd="$1"
    bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c "command -v ${cmd}" >/dev/null 2>&1
}

artifact_release_tag() {
    local name
    name="$(basename "$1")"
    name="${name%.img.xz}"
    name="${name%.img}"
    printf '%s\n' "${name}"
}

manifest_path_for_artifact() {
    local artifact="$1"
    printf '%s/%s.packages.txt\n' "${DIST_DIR}" "$(artifact_release_tag "${artifact}")"
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
    local img_path failures=0

    # shellcheck disable=SC1091
    source "${LIB_DIR}/setup_binfmt.sh"

    if [ -z "${artifact}" ]; then
        artifact="$(find_latest_artifact)"
    fi
    [ -f "${artifact}" ] || die "Artifact not found: ${artifact}"
    case "${artifact}" in
        *.img.xz) ;;
        *) die "Expected a .img.xz artifact, got: ${artifact}" ;;
    esac

    log "Verifying ${artifact}"

    if [ -f "${artifact}.sha256" ]; then
        sha256sum -c "${artifact}.sha256" || die "Artifact checksum mismatch"
        pass "artifact SHA256"
    fi

    command -v xz >/dev/null || die "xz not found"
    img_path="/tmp/ddm-verify-working.img"
    rm -f "${img_path}"
    log "Decompressing ${artifact} for verification"
    xz -dc "${artifact}" > "${img_path}"

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

    for pkg in binutils-aarch64-linux-gnu python3.13 python3.13-minimal perl; do
        if package_installed_in_chroot "${pkg}"; then
            die "required removal still installed: ${pkg}"
        fi
    done
    pass "binutils-aarch64-linux-gnu, python3.13/python3.13-minimal, and perl absent from image"

    for pkg in chromium firefox lightdm wf-panel-pi rpd-wayland-core evince gvfs rpi-connect-lite packagekit; do
        if package_installed_in_chroot "${pkg}"; then
            die "desktop/addon package still installed: ${pkg}"
        fi
    done
    pass "desktop shell, residue, and browser addons absent from image"

    for pkg in openssh-server wpasupplicant bluez avahi-daemon blueman pi-bluetooth; do
        if package_installed_in_chroot "${pkg}"; then
            die "networking package still installed: ${pkg}"
        fi
    done
    pass "stripped networking userland absent from image"

    for pkg in dhcpcd-base iproute2; do
        if ! package_installed_in_chroot "${pkg}"; then
            die "required networking keep package missing: ${pkg}"
        fi
    done
    pass "dhcpcd-base and iproute2 present"

    for pkg in cron cron-daemon-common; do
        if package_installed_in_chroot "${pkg}"; then
            die "cron package still installed: ${pkg}"
        fi
    done
    pass "cron packages absent from image"

    for pkg in fonts-freefont-ttf fonts-urw-base35; do
        if package_installed_in_chroot "${pkg}"; then
            die "extra font package still installed: ${pkg}"
        fi
    done
    pass "extra fonts absent from image"

    for pkg in fonts-dejavu-core fonts-dejavu-mono fonts-liberation; do
        if ! package_installed_in_chroot "${pkg}"; then
            die "required font keep package missing: ${pkg}"
        fi
    done
    pass "fonts-dejavu-core, fonts-dejavu-mono, and fonts-liberation present"

    for pkg in linux-image-rpi-v8 linux-base-rpi-v8; do
        if package_installed_in_chroot "${pkg}"; then
            die "generic v8 kernel package still installed: ${pkg}"
        fi
    done
    if bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c \
        "dpkg-query -W -f='\${Package}\n' 'linux-image-*-rpi-v8' 2>/dev/null | grep -q ."
    then
        die "versioned linux-image-*-rpi-v8 package still installed"
    fi
    if bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c \
        "dpkg-query -W -f='\${Package}\n' 'linux-base-*-rpi-v8' 2>/dev/null | grep -q ."
    then
        die "versioned linux-base-*-rpi-v8 package still installed"
    fi
    pass "generic rpi-v8 kernel absent from image"

    for pkg in linux-image-rpi-2712 linux-base-rpi-2712; do
        if ! package_installed_in_chroot "${pkg}"; then
            die "required Pi 5 kernel package missing: ${pkg}"
        fi
    done
    pass "Pi 5 rpi-2712 kernel present"

    # alsa-utils / dconf-cli are hard deps of raspi-config (via raspberrypi-sys-mods
    # first-boot resize); that is not intentional audio userland. PipeWire stays out.
    for pkg in pipewire pipewire-pulse wireplumber; do
        if package_installed_in_chroot "${pkg}"; then
            die "audio package still installed: ${pkg}"
        fi
    done
    pass "PipeWire audio daemons absent from image"

    if ! package_installed_in_chroot libldacbt-enc2; then
        die "required package missing: libldacbt-enc2 (gstreamer1.0-plugins-bad)"
    fi
    pass "libldacbt-enc2 present"

    if ! package_installed_in_chroot raspberrypi-sys-mods; then
        die "required package missing: raspberrypi-sys-mods (first-boot rootfs resize)"
    fi
    pass "raspberrypi-sys-mods present"

    for pkg in alsa-utils dconf-cli; do
        if ! package_installed_in_chroot "${pkg}"; then
            die "required raspi-config keep package missing: ${pkg}"
        fi
    done
    pass "alsa-utils and dconf-cli present (raspi-config deps)"

    if ! bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c \
        '[ -x /usr/share/initramfs-tools/scripts/local-premount/resize_early ]'
    then
        die "resize_early initramfs hook missing"
    fi
    pass "resize_early initramfs hook present"

    if ! bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c '
        cmdline=/boot/firmware/cmdline.txt
        [ -f "${cmdline}" ] || exit 1
        grep -Eq "(^|[[:space:]])resize([[:space:]]|$)" "${cmdline}"
    '
    then
        die "cmdline.txt missing resize token for first-boot partition expand"
    fi
    pass "cmdline.txt contains resize token"

    if ! bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c '
        link=/etc/systemd/system/sysinit.target.wants/rpi-resize.service
        [ -L "${link}" ] || exit 1
        target="$(readlink -f "${link}")"
        case "${target}" in
            */rpi-resize.service) exit 0 ;;
            *) exit 1 ;;
        esac
    '
    then
        die "rpi-resize.service not enabled under sysinit.target.wants"
    fi
    pass "rpi-resize.service enabled under sysinit.target.wants"

    if ! bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c '
        mid=/etc/machine-id
        [ -e "${mid}" ] || exit 1
        # systemd ConditionFirstBoot: empty or the literal "uninitialized"
        if [ ! -s "${mid}" ]; then
            exit 0
        fi
        tr -d "\n" < "${mid}" | grep -qx uninitialized
    '
    then
        die "machine-id is not uninitialized (ConditionFirstBoot would skip rpi-resize)"
    fi
    pass "machine-id uninitialized for first-boot resize"

    for pkg in labwc cage libwayland-client0 libwlroots-0.19 mesa-va-drivers libva-drm2 ffmpeg thorium-browser; do
        if ! package_installed_in_chroot "${pkg}"; then
            die "required kiosk package missing: ${pkg}"
        fi
    done
    pass "kiosk Wayland/GPU/Thorium packages present"

    for cmd in cage thorium-browser; do
        if ! command_in_chroot "${cmd}"; then
            die "required binary missing from PATH: ${cmd}"
        fi
    done
    pass "cage and thorium-browser binaries on PATH"

    # Boot policy: console multi-user, no graphical DM leftovers.
    local default_target
    default_target="$(
        bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c '
            if [ -L /etc/systemd/system/default.target ]; then
                readlink -f /etc/systemd/system/default.target
            elif [ -L /lib/systemd/system/default.target ]; then
                readlink -f /lib/systemd/system/default.target
            else
                echo MISSING
            fi
        '
    )"
    case "${default_target}" in
        */multi-user.target) pass "default.target is multi-user.target" ;;
        *) die "default.target is not multi-user.target (got: ${default_target})" ;;
    esac

    if bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c \
        '[ -e /etc/systemd/system/display-manager.service ]'
    then
        die "display-manager.service still present under /etc/systemd/system/"
    fi
    pass "display-manager.service absent"

    if bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c \
        'grep -q rpi-first-boot-wizard /etc/systemd/system/getty@tty1.service.d/autologin.conf 2>/dev/null'
    then
        die "getty tty1 still autologins rpi-first-boot-wizard"
    fi
    pass "getty tty1 not autologin for rpi-first-boot-wizard"

    if ! bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c '
        link=/etc/systemd/system/getty.target.wants/getty@tty1.service
        [ -L "${link}" ] || exit 1
        target="$(readlink -f "${link}")"
        case "${target}" in
            */getty@.service) exit 0 ;;
            *) exit 1 ;;
        esac
    '
    then
        die "getty@tty1.service not enabled under getty.target.wants"
    fi
    pass "getty@tty1.service enabled under getty.target.wants"

    if package_installed_in_chroot plymouth; then
        die "plymouth still installed"
    fi
    if bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c \
        'ls /etc/rc2.d/*plymouth* /etc/rcS.d/*plymouth* /etc/init.d/plymouth /etc/init.d/plymouth-log 2>/dev/null | grep -q .'
    then
        die "plymouth SysV leftovers still present"
    fi
    pass "plymouth package and SysV leftovers absent"

    if ! package_installed_in_chroot sudo; then
        die "required package missing: sudo"
    fi
    pass "sudo package present"

    if ! bash "${LIB_DIR}/chroot_exec.sh" /bin/bash -c '
        id rpi >/dev/null 2>&1 || exit 1
        shell="$(getent passwd rpi | cut -d: -f7)"
        case "${shell}" in
            /usr/sbin/nologin|/sbin/nologin|/bin/false|*/nologin) exit 1 ;;
        esac
        id -nG rpi | tr " " "\n" | grep -qx sudo
    '
    then
        die "user rpi missing, has nologin shell, or is not in group sudo"
    fi
    pass "user rpi present with login shell and sudo group"

    # shellcheck disable=SC1091
    source "${LIB_DIR}/umount_image.sh"

    rm -f "${img_path}"
    pass "verification complete for ${artifact}"
}

main "$@"
