# U-Boot script: boot the ostree deployment that bootc selected.
#
# U-Boot's script bootmeth finds this on the ESP and sets devtype, devnum and
# distro_bootpart. ostree's U-Boot backend (sysroot.bootloader=uboot) rewrites
# /boot/loader/uEnv.txt on every `bootc upgrade` / `bootc rollback`, so this
# script never needs to change when the OS updates.
#
# kernel_addr_r is used as scratch space for the text files because
# scriptaddr holds this script while it runs.

setenv fdtfile allwinner/sun50i-h700-anbernic-rg35xx-sp.dtb
setenv bootslot 1

setenv ostreepart
part list ${devtype} ${devnum} parts
for p in ${parts}; do
  if test -e ${devtype} ${devnum}:${p} /boot/loader/uEnv.txt; then
    setenv ostreepart ${p}
  fi
done
if test -z "${ostreepart}"; then
  echo "rg35xxsp: no /boot/loader/uEnv.txt found on ${devtype} ${devnum}"
  exit
fi

load ${devtype} ${devnum}:${ostreepart} ${kernel_addr_r} /boot/loader/uEnv.txt
env import -t ${kernel_addr_r} ${filesize}

# Per-device overrides from the ESP, as plain name=value lines, e.g.
#   fdtfile=allwinner/sun50i-h700-anbernic-rg35xx-sp-v2-panel.dtb
#   bootslot=2        (boot the previous deployment)
if test -e ${devtype} ${devnum}:${distro_bootpart} /rg35xxsp.txt; then
  load ${devtype} ${devnum}:${distro_bootpart} ${kernel_addr_r} /rg35xxsp.txt
  env import -t ${kernel_addr_r} ${filesize}
fi

if test "${bootslot}" = "2" && test -n "${kernel_image2}"; then
  echo "rg35xxsp: booting previous deployment"
  setenv kernel_image ${kernel_image2}
  setenv ramdisk_image ${ramdisk_image2}
  setenv fdtdir ${fdtdir2}
  setenv bootargs ${bootargs2}
fi

echo "rg35xxsp: ${kernel_image} with ${fdtfile}"
load ${devtype} ${devnum}:${ostreepart} ${kernel_addr_r} ${kernel_image} || exit
load ${devtype} ${devnum}:${ostreepart} ${ramdisk_addr_r} ${ramdisk_image} || exit
setenv ramdisk_size ${filesize}
load ${devtype} ${devnum}:${ostreepart} ${fdt_addr_r} ${fdtdir}/${fdtfile} || exit
booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}
