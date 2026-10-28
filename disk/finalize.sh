#!/usr/bin/env bash
# Make a disk image produced by `bootc install to-disk --bootloader none`
# bootable on the RG35XX-SP. Runs inside the built image (privileged), after
# the install, with the image file at $1.
#
#   1. Switch ostree to its U-Boot backend so every future deploy rewrites
#      /boot/loader/uEnv.txt (the backend only updates an existing file, so
#      seed the first one from the BLS entry bootc just wrote).
#   2. Put boot.scr and an override template on the ESP.
#   3. Write U-Boot at 128 KiB, past the GPT, where the H700 boot ROM also looks.
#
# Environment:
#   RAM                 lpddr4 (default) or lpddr3 for the 2026 board revision
#   ROOT_PASSWORD_HASH  optional crypt(3) hash for root, for console login
set -euo pipefail

img="${1:?usage: $0 <disk-image>}"
ram="${RAM:-lpddr4}"
bootloader_dir=/usr/lib/rg35xxsp/bootloader
uboot="${bootloader_dir}/u-boot-${ram}.bin"
[ -f "${uboot}" ] || { echo "No U-Boot build for RAM=${ram}" >&2; exit 1; }

loop="$(losetup -P --show -f "${img}")"
mnt="$(mktemp -d)"
cleanup() {
  umount -R "${mnt}/esp" "${mnt}/root" 2>/dev/null || true
  losetup -d "${loop}"
}
trap cleanup EXIT
udevadm settle 2>/dev/null || true

part_by() { # lsblk column, value
  lsblk -lnpo "PATH,$1" "${loop}" | awk -v v="$2" '$2 == v { print $1 }'
}
esp="$(part_by PARTLABEL EFI-SYSTEM)"
root="$(part_by LABEL root)"
[ -n "${esp}" ] && [ -n "${root}" ] || { echo "Could not find ESP/root on ${loop}" >&2; lsblk -o +PARTLABEL,LABEL "${loop}" >&2; exit 1; }

mkdir -p "${mnt}/root" "${mnt}/esp"
mount "${root}" "${mnt}/root"
mount "${esp}" "${mnt}/esp"
sysroot="${mnt}/root"

ostree config --repo "${sysroot}/ostree/repo" set sysroot.bootloader uboot

# Same format as ostree's U-Boot backend (ostree-bootloader-uboot.c): paths get
# a /boot prefix, and /boot/boot -> . makes them resolve from the partition root.
entries=("${sysroot}"/boot/loader/entries/*.conf)
[ "${#entries[@]}" -eq 1 ] || { echo "Expected one BLS entry, found ${#entries[@]}" >&2; exit 1; }
bls_get() { awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }' "${entries[0]}"; }
{
  echo "kernel_image=/boot$(bls_get linux)"
  echo "ramdisk_image=/boot$(bls_get initrd)"
  fdtdir="$(bls_get fdtdir)"
  [ -z "${fdtdir}" ] || echo "fdtdir=/boot${fdtdir}"
  echo "bootargs=$(bls_get options)"
} > "${sysroot}/boot/loader/uEnv.txt"
echo "Seeded uEnv.txt:"
cat "${sysroot}/boot/loader/uEnv.txt"
grep -q '^fdtdir=' "${sysroot}/boot/loader/uEnv.txt" || { echo "BLS entry has no fdtdir; device trees missing from the image?" >&2; exit 1; }

if [ -n "${ROOT_PASSWORD_HASH:-}" ]; then
  deployment="$(ls -d "${sysroot}"/ostree/deploy/*/deploy/*.0 | head -n1)"
  usermod -R "${deployment}" -p "${ROOT_PASSWORD_HASH}" root
fi

install -m644 "${bootloader_dir}/boot.scr" "${mnt}/esp/boot.scr"
cat > "${mnt}/esp/rg35xxsp.txt" <<'EOF'
# Per-device boot overrides, read by boot.scr. Uncomment to use.
#
# Newer RG35XX-SP units ship with a different panel. If the screen stays dark,
# try the v2 panel device tree:
#fdtfile=allwinner/sun50i-h700-anbernic-rg35xx-sp-v2-panel.dtb
#
# Boot the previous deployment (same as `bootc rollback`, but from a PC):
#bootslot=2
EOF

dd if="${uboot}" of="${loop}" bs=1K seek=128 conv=notrunc,fsync status=none
echo "Wrote $(basename "${uboot}") at 128 KiB"
