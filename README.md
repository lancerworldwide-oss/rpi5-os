# Lancer Next Gen Raspberry Pi 5 OS Base Image Creator

This project creates a RPI 5 OS base image suitable for the next gen software packages.

## Architecture

The core of the project takes an upstream RPI5 OS image, strips out all the unnecessary preinstalled packages and repackages it for distribution as a minimal base OS image. The project is implemented as a dev container based on a Dockerfile that does all the heavy lifting. The Dockerfile is based on Debian Trixie for x86_64 which the RPI5 OS is also based on. The container installs QEMU ARM64 user mode emulation for performing a chroot into Trixie ARM64 sandboxes. The process of generating a clean NGSW RPI 5 image is performed in the 'gen_image.sh' shell script. The container has all the tools and utilities necessary to create the image.

## packages.txt

This file contains the list of packages that should be removed from the upstream image.

## gen_image.sh

This shell script is responsible for generating the image. It is parameterized using environment variables that can be passed from the Docker host or set in the dev container configuration file. The basic order of operations follow:

- Download a RPI 5 OS image from the RPI_SOURCE_IMG environment variable if it is set, otherwise download the latest.
- The image is compared to the RPI_SOURCE_IMG_MD5 environment variable MD5 checksum if it exists to validate the integrity.
- If RPI_SOURCE_IMG_MD5 is absent but  RPI_SOURCE_IMG is present then checksum validation is skipped.
- If neither RPI_SOURCE_IMG nor RPI_SOURCE_IMG_MD5 are provided then defaults are used.
- The source image is copied to a working image for modifications so in the event of a failure the download operation maybe skipped.
- The ARM64 working image is mounted into a temporary sandbox, filesystems mounted in the sandbox and prepared for QEMU chroot user emulation.
- The script performs a chroot into the sandbox to prepare the image.
- In the chroot environment the packages.txt is processed and the listed APT packages are removed.
- Base image is minimalized for distribution by removing temporary files and reconfiguring packages as necessary for a minimal OS.
- Image file system is defragmented.
- Free space is zeroed.
- Chroot environment is exited and file systems unmounted.
- The root file system partition is truncated according to the last used sector plus a little padding for good measure.
- Resulting image is renamed to designate it has been minimalized then its tared and gzipped.
