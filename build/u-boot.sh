#!/usr/bin/env bash
# Cross-compile TF-A (BL31) and U-Boot for both H700 RAM variants, and compile
# the boot script. Runs in the native (x86_64) cross stage of the Containerfile.
#
# Output under $1:
#   u-boot-lpddr4.bin, u-boot-lpddr3.bin   (u-boot-sunxi-with-spl.bin images)
#   boot.scr
set -euo pipefail

out="${1:?usage: $0 <outdir>}"
src_root="$(cd "$(dirname "$0")/.." && pwd)"
vendor="${src_root}/vendor/rocknix"

TFA_VERSION=2.12.0
TFA_SHA256=d95aaf292792c98035910d7e6c64ebfb297c897fef510415db1612f6d39f9223
UBOOT_VERSION=v2026.01
UBOOT_SHA256=03bb43c58d2343ee48dd191e0f181f0108425b179d84519add3a977071c3f654

export CROSS_COMPILE=aarch64-linux-gnu-
jobs="$(nproc)"

fetch() { # url sha256 dest
  curl -fsSL -o "$3" "$1"
  echo "$2  $3" | sha256sum -c -
}

work="$(mktemp -d)"
cd "${work}"
mkdir -p "${out}"

fetch "https://github.com/TrustedFirmware-A/trusted-firmware-a/archive/v${TFA_VERSION}.tar.gz" \
  "${TFA_SHA256}" tfa.tar.gz
tar -xf tfa.tar.gz
# TF-A >= 2.12 builds sun50i platforms with LTO.
make -C "trusted-firmware-a-${TFA_VERSION}" -j"${jobs}" CFLAGS="-ffat-lto-objects" PLAT=sun50i_h616 bl31
bl31="${work}/trusted-firmware-a-${TFA_VERSION}/build/sun50i_h616/release/bl31.bin"

fetch "https://github.com/u-boot/u-boot/archive/${UBOOT_VERSION}.tar.gz" "${UBOOT_SHA256}" u-boot.tar.gz
tar -xf u-boot.tar.gz
ubsrc="${work}/u-boot-${UBOOT_VERSION#v}"
for p in "${vendor}"/u-boot/patches/*.patch; do
  echo "Applying $(basename "${p}")"
  patch -d "${ubsrc}" -p1 --no-backup-if-mismatch < "${p}"
done
cp "${vendor}"/u-boot/configs/*_defconfig "${ubsrc}/configs/"
# disk/boot.cmd needs the script bootmeth and ext4 reads from the ostree sysroot.
for cfg in "${ubsrc}"/configs/anbernic_rg35xx_h700_lpddr*_defconfig; do
  printf '%s\n' CONFIG_BOOTMETH_SCRIPT=y CONFIG_FS_EXT4=y CONFIG_CMD_EXT4=y \
    CONFIG_CMD_FS_GENERIC=y CONFIG_CMD_IMPORTENV=y >> "${cfg}"
done

# SPL + U-Boot proper must fit between the 128 KiB boot ROM offset and the
# first partition at 1 MiB.
max_size=$(( 1024 * 1024 - 128 * 1024 ))
for ram in lpddr4 lpddr3; do
  make -C "${ubsrc}" mrproper
  make -C "${ubsrc}" "anbernic_rg35xx_h700_${ram}_defconfig"
  # U-Boot's bundled pylibfdt does not build with current swig/Python;
  # NO_PYTHON skips it and binman uses the system python3-libfdt instead.
  make -C "${ubsrc}" -j"${jobs}" BL31="${bl31}" NO_PYTHON=1 CONFIG_MKIMAGE_DTC_PATH=scripts/dtc/dtc
  size="$(stat -c %s "${ubsrc}/u-boot-sunxi-with-spl.bin")"
  if [ "${size}" -gt "${max_size}" ]; then
    echo "u-boot-sunxi-with-spl.bin for ${ram} is ${size} bytes; max is ${max_size}" >&2
    exit 1
  fi
  install -m644 "${ubsrc}/u-boot-sunxi-with-spl.bin" "${out}/u-boot-${ram}.bin"
done

mkimage -A arm64 -T script -C none -n "rg35xxsp ostree boot" \
  -d "${src_root}/disk/boot.cmd" "${out}/boot.scr"
rm -rf "${work}"
