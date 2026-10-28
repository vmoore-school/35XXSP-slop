#!/usr/bin/env bash
# Copy the H700 hardware-support bits we reuse from ROCKNIX into vendor/rocknix,
# pinned to a single upstream commit so every change shows up in git diff.
#
# Usage: scripts/vendor-rocknix.sh <rocknix-commit>
set -euo pipefail

commit="${1:?usage: $0 <rocknix-commit>}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dest="${repo_root}/vendor/rocknix"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

p=projects/ROCKNIX
git clone -q --filter=blob:none --no-checkout https://github.com/ROCKNIX/distribution.git "${work}/src"
git -C "${work}/src" sparse-checkout set --no-cone \
  "${p}/devices/H700/linux" \
  "${p}/devices/H700/patches/linux" \
  "${p}/devices/H700/packages/u-boot-DDR4" \
  "${p}/devices/H700/packages/u-boot-DDR3" \
  "${p}/packages/linux/patches/mainline" \
  "${p}/packages/linux/patches/7.2" \
  "${p}/packages/linux-firmware/kernel-firmware/extra-firmware/panels"
git -C "${work}/src" checkout -q "${commit}"
s="${work}/src/${p}"

rm -rf "${dest}"
mkdir -p "${dest}"/kernel/patches/{mainline,7.2,h700} "${dest}"/kernel/dts \
  "${dest}"/firmware/panels "${dest}"/u-boot/patches "${dest}"/u-boot/configs

# Kernel patches, grouped in the order ROCKNIX applies them for H700:
# packages/linux/patches/mainline, then .../7.2, then devices/H700/patches/linux.
cp "${s}"/packages/linux/patches/mainline/*.patch "${dest}/kernel/patches/mainline/"
cp "${s}"/packages/linux/patches/7.2/*.patch "${dest}/kernel/patches/7.2/"
cp "${s}"/devices/H700/patches/linux/*.patch "${dest}/kernel/patches/h700/"
cp -r "${s}"/devices/H700/linux/dts/. "${dest}/kernel/dts/"
cp "${s}"/devices/H700/linux/linux.aarch64.conf "${dest}/kernel/"

cp "${s}"/packages/linux-firmware/kernel-firmware/extra-firmware/panels/*.panel "${dest}/firmware/panels/"

# The DDR4 and DDR3 U-Boot packages carry identical patches; keep one copy.
cp "${s}"/devices/H700/packages/u-boot-DDR4/patches/*.patch "${dest}/u-boot/patches/"
cp "${s}"/devices/H700/packages/u-boot-DDR4/sources/configs/*_defconfig "${dest}/u-boot/configs/"
cp "${s}"/devices/H700/packages/u-boot-DDR3/sources/configs/*_defconfig "${dest}/u-boot/configs/"

echo "${commit}" > "${dest}/COMMIT"
echo "Vendored ROCKNIX ${commit} into ${dest}"
