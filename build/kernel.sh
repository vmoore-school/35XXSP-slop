#!/usr/bin/env bash
# Cross-compile the H700 kernel, its device trees and the rocknix-joypad module.
# Runs in the native (x86_64) cross stage of the Containerfile.
#
# Output layout under $1 (the ostree/bootc kernel convention):
#   usr/lib/modules/$kver/vmlinuz
#   usr/lib/modules/$kver/dtb/allwinner/*.dtb
#   usr/lib/modules/$kver/kernel/...        (modules)
set -euo pipefail

out="${1:?usage: $0 <outdir>}"
src_root="$(cd "$(dirname "$0")/.." && pwd)"
vendor="${src_root}/vendor/rocknix"

LINUX_VERSION=7.2
LINUX_SHA256=f9fef3d14c0df53819026f4be74459835c2a0b0dcbf5b5bbd9ea19f0829402b3
JOYPAD_COMMIT=005033d1ddd8746c771f2c81f1174f2d892541c9
JOYPAD_SHA256=7a9a90d9d25d48384771bf8fe7cfb53bba708b64aa4e56d44e71205a8bcc699a

export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
jobs="$(nproc)"

fetch() { # url sha256 dest
  curl -fsSL -o "$3" "$1"
  echo "$2  $3" | sha256sum -c -
}

work="$(mktemp -d)"
cd "${work}"
fetch "https://www.kernel.org/pub/linux/kernel/v${LINUX_VERSION%%.*}.x/linux-${LINUX_VERSION}.tar.xz" \
  "${LINUX_SHA256}" linux.tar.xz
tar -xf linux.tar.xz
cd "linux-${LINUX_VERSION}"

for dir in mainline 7.2 h700; do
  for p in "${vendor}/kernel/patches/${dir}"/*.patch; do
    echo "Applying ${dir}/$(basename "${p}")"
    patch -p1 --no-backup-if-mismatch < "${p}"
  done
done
cp -r "${vendor}/kernel/dts/." arch/arm64/boot/dts/

# Firmware that gets linked into the kernel image.
mkdir -p external-firmware/{panels,rtw88,rtl_bt}
cp "${vendor}"/firmware/panels/*.panel external-firmware/panels/
for f in rtw88/rtw8821c_fw.bin rtl_bt/rtl8821cs_config.bin rtl_bt/rtl8821cs_fw.bin; do
  if [ -f "/usr/lib/firmware/${f}" ]; then
    cp "/usr/lib/firmware/${f}" "external-firmware/${f}"
  else
    zstd -dq "/usr/lib/firmware/${f}.zst" -o "external-firmware/${f}"
  fi
done
fw_list="$(cd external-firmware && find . -type f | sed 's|^\./||' | sort | xargs)"

cp "${vendor}/kernel/linux.aarch64.conf" .config
scripts/kconfig/merge_config.sh -m .config "${src_root}/build/kernel.config"
scripts/config --set-str CONFIG_EXTRA_FIRMWARE "${fw_list}"
make olddefconfig

# Build every H700 board's DTB so one image can serve panel revisions too.
dtbs="$(cd arch/arm64/boot/dts && ls allwinner/sun50i-h700-*.dts | sed 's/\.dts$/.dtb/')"
DTC_FLAGS=-@ make -j"${jobs}" Image modules ${dtbs}
kver="$(make -s kernelrelease)"

moddir="${out}/usr/lib/modules/${kver}"
make INSTALL_MOD_PATH="${out}/usr" INSTALL_MOD_STRIP=1 modules_install
install -Dm644 arch/arm64/boot/Image "${moddir}/vmlinuz"
for dtb in ${dtbs}; do
  install -Dm644 "arch/arm64/boot/dts/${dtb}" "${moddir}/dtb/${dtb}"
done

# Out-of-tree joypad driver used by the H700 device trees (patch 0140).
cd "${work}"
fetch "https://github.com/hackbar/rocknix-joypad/archive/${JOYPAD_COMMIT}.tar.gz" \
  "${JOYPAD_SHA256}" joypad.tar.gz
tar -xf joypad.tar.gz
# DEVICE selects the driver variant; left empty, its Makefile builds only the
# plain rocknix-joypad, not the singleadc one the H700 device trees use.
make -C "${work}/linux-${LINUX_VERSION}" M="${work}/rocknix-joypad-${JOYPAD_COMMIT}" DEVICE=H700 -j"${jobs}" modules
install -Dm644 -t "${moddir}/extra/rocknix-joypad" "${work}/rocknix-joypad-${JOYPAD_COMMIT}"/*.ko
"${CROSS_COMPILE}strip" --strip-debug "${moddir}"/extra/rocknix-joypad/*.ko

# Drop build-tree symlinks that point into the throwaway work dir.
rm -f "${moddir}/build" "${moddir}/source"
depmod -b "${out}/usr" "${kver}"
echo "${kver}" > "${out}/kernel-release"
rm -rf "${work}"
