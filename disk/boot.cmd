# U-Boot script: boot the ostree deployment that bootc selected.
#
# U-Boot's script bootmeth finds this on the ESP and sets devtype, devnum and
# distro_bootpart. ostree's U-Boot backend (sysroot.bootloader=uboot) rewrites
# /boot/loader/uEnv.txt on every `bootc upgrade` / `bootc rollback`, so this
# script never needs to change when the OS updates.
#
# kernel_addr_r is used as scratch space for the text files because
# scriptaddr holds this script while it runs.
#
# There's no display in U-Boot, so progress is written to /uboot.log on the ESP
# for reading from a PC, and shown by blinking the status LED (GPIO 267, PI11)
# once per stage number. pxefile_addr_r is free space between the device tree
# and the initramfs, so logging never clobbers what is being booted.

setenv fdtfile allwinner/sun50i-h700-anbernic-rg35xx-sp.dtb
setenv bootslot 1
setenv ostreepart none
setenv kernel_image none
setenv rg_log 'env export -t ${pxefile_addr_r} stage bootslot ostreepart kernel_image fdtfile; fatwrite ${devtype} ${devnum}:${distro_bootpart} ${pxefile_addr_r} /uboot.log ${filesize}'
setenv rg_blink 'sleep 1; for i in ${blinks}; do gpio toggle 267; sleep 0.3; gpio toggle 267; sleep 0.3; done'

setenv stage "1 boot.scr started"
run rg_log
setenv blinks "1"
run rg_blink

part list ${devtype} ${devnum} parts
for p in ${parts}; do
  if test -e ${devtype} ${devnum}:${p} /boot/loader/uEnv.txt; then
    setenv ostreepart ${p}
  fi
done
if test "${ostreepart}" = "none"; then
  setenv stage "2 FAILED: no /boot/loader/uEnv.txt on any partition"
  run rg_log
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

setenv stage "3 loading kernel, initramfs and device tree"
run rg_log
setenv blinks "1 2 3"
run rg_blink
echo "rg35xxsp: ${kernel_image} with ${fdtfile}"
setenv loaded none
if load ${devtype} ${devnum}:${ostreepart} ${kernel_addr_r} ${kernel_image}; then
  setenv loaded kernel
  if load ${devtype} ${devnum}:${ostreepart} ${ramdisk_addr_r} ${ramdisk_image}; then
    setenv ramdisk_size ${filesize}
    setenv loaded initramfs
    if load ${devtype} ${devnum}:${ostreepart} ${fdt_addr_r} ${fdtdir}/${fdtfile}; then
      setenv loaded all
    fi
  fi
fi
if test "${loaded}" != "all"; then
  setenv stage "3 FAILED: loaded only up to: ${loaded}"
  run rg_log
  exit
fi

# A successful booti never returns, so stage 4 is the last thing U-Boot logs.
setenv stage "4 starting kernel"
run rg_log
setenv blinks "1 2 3 4"
run rg_blink
booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}
setenv stage "4 FAILED: booti returned"
run rg_log
