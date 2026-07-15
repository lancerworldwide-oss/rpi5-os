#!/bin/bash
# Register QEMU ARM64 binfmt handlers for chroot child process execution.

set -euo pipefail

if [ ! -f /proc/sys/fs/binfmt_misc/register ]; then
    sudo mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
fi

if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ] && [ -w /proc/sys/fs/binfmt_misc/register ]; then
    # CF flags: C = preserve credentials; F = resolve interpreter inside the binary's filesystem root (chroot).
    echo ':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64-static:CF' \
        | sudo tee /proc/sys/fs/binfmt_misc/register >/dev/null
fi

sudo update-binfmts --enable qemu-aarch64 2>/dev/null || true
