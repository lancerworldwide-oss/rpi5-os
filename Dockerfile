# DDM image build environment: Debian Trixie x86_64 host with QEMU ARM64 user emulation.
#
# Build:
#   docker build -t ddm-image-builder .
#
# Run (privileged, workspace mounted):
#   docker run --rm -it --privileged -v ${PWD}:/workspace ddm-image-builder

FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    binfmt-support \
    ca-certificates \
    curl \
    dosfstools \
    e2fsprogs \
    gzip \
    kpartx \
    parted \
    qemu-user-static \
    sudo \
    tar \
    util-linux \
    wget \
    xz-utils \
    zerofree \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash user \
    && echo "user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/user \
    && chmod 0440 /etc/sudoers.d/user

WORKDIR /workspace
USER user
