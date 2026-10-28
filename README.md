# rg35xxsp-bootc

A [bootc](https://github.com/bootc-dev/bootc) image for the Anbernic RG35XX-SP
(Allwinner H700), built on Debian testing. The OS is a container image; the
device updates atomically with `bootc upgrade` and can roll back to the
previous deployment.

Hardware support (kernel patches, device trees, panel firmware, U-Boot DRAM
config) comes from [ROCKNIX](https://github.com/ROCKNIX/distribution), vendored
at a pinned commit in `vendor/rocknix/`. The bootc layout follows
[bootcrew](https://github.com/bootcrew/mono)'s Debian image, but uses bootc's
**ostree backend** (not composefs-native), with ostree's own composefs mode
also disabled.

## Status

Scaffold, not yet booted on hardware. No frontend or emulators yet.

Verified locally: the kernel and U-Boot stages build. The whole pipeline
(image build, `bootc container lint`, `bootc install to-disk`, finalize) was
also run end to end with an amd64 build of the image. The real arm64 image is
built only by CI.

## How it boots

```
SD card
├─ 0–1 MiB     GPT, then U-Boot (SPL + TF-A + U-Boot) at 256 KiB
├─ p1  ESP     vfat: boot.scr, rg35xxsp.txt (per-device overrides)
└─ p2  root    ext4: ostree sysroot, /boot/loader/uEnv.txt
```

1. The H700 boot ROM finds U-Boot at 256 KiB, the H616 family's fallback
   location (older Allwinner SoCs use 128 KiB). The usual 8 KiB location
   overlaps the GPT.
2. U-Boot runs `boot.scr` from the ESP (`disk/boot.cmd`).
3. `boot.scr` imports `/boot/loader/uEnv.txt` and boots that kernel, initramfs
   and device tree.
4. ostree is configured with `sysroot.bootloader=uboot`, so every
   `bootc upgrade` and `bootc rollback` rewrites `uEnv.txt`. `boot.scr` itself
   never changes.

bootc's own bootloader step on the ostree backend only supports GRUB via
bootupd, so the image sets `bootloader = "none"`. `disk/finalize.sh` does the
device-specific setup after `bootc install to-disk`.

Kernel, initramfs and device trees all live in the image
(`/usr/lib/modules/$kver/{vmlinuz,initramfs.img,dtb/}`), so they update with
the OS. U-Boot itself sits outside the deployment and does not update
automatically. A copy ships in `/usr/lib/rg35xxsp/bootloader/`.

## Building

You need podman and [just](https://github.com/casey/just).

**In CI (recommended):** push to GitHub. `.github/workflows/build.yaml` runs
on GitHub's arm64 runners, which are free for public repositories. It pushes
`ghcr.io/<owner>/rg35xxsp-bootc:latest` and uploads compressed disk images
for both RAM variants as a workflow artifact.

**Locally on x86_64:** the kernel and U-Boot are cross-compiled natively.
The Debian and bootc stages run as arm64, which needs qemu-user binfmt
registered with the fix-binary (`F`) flag, e.g. Fedora's `qemu-user-static`
package. Without it, only the cross stages build:

```sh
just build-stage kernel       # or: bootloader
just build                    # full arm64 image (slow under emulation)
just disk-image               # -> output/rg35xxsp.img
just disk-image lpddr3        # 2026 board revision with LPDDR3 RAM
just flash /dev/sdX
```

`PODMAN="pkexec podman"` runs the root steps through polkit instead of sudo.
`PLATFORM=linux/amd64` builds the whole pipeline without emulation for a quick
smoke test; the resulting disk image won't boot the device.

`ROOT_PASSWORD_HASH='<crypt hash>' just disk-image` sets a root password for
console login (`openssl passwd -6`). A UART on the board's test pads
(`ttyS0`, 115200) is the best way to watch the first boots.

## Debugging without a serial console

The ESP is typed as an ordinary data partition labelled `RG35XXSP`, so it
mounts on any PC. The display stays dark until Linux's panel driver loads, so:

- **LED:** `boot.scr` blinks the status LED once when it starts, 3 times
  before loading the kernel, and 4 times right before starting it.
- **`uboot.log`** on the ESP records the last U-Boot stage reached.
  Stage 4 means the kernel was started.
- **`logs/`** on the ESP gets the journal, dmesg and `status.txt` (IP address,
  `bootc status`, failed units) 45 s after boot and every 5 minutes after.
  The previous boot's journal is kept too.
- **`provision/`**: rename `wifi.txt.example` and `authorized_keys.example`
  and fill them in to get WiFi and `ssh root@<ip>` without a keyboard.

## On the device

- **Updates:** `bootc upgrade`, then reboot.
- **Rollback:** `bootc rollback`, then reboot. If the device won't boot, put
  `bootslot=2` in `rg35xxsp.txt` on the SD card's ESP from a PC.
- **Dark screen:** newer units have a different panel. Uncomment the v2-panel
  `fdtfile=` line in `rg35xxsp.txt`.
- **WiFi:** `iwctl` (iwd), with systemd-networkd handling DHCP.

## Updating ROCKNIX bits

```sh
just vendor <rocknix-commit>
```

Kernel, TF-A, U-Boot and joypad versions and hashes live at the top of
`build/kernel.sh` and `build/u-boot.sh`. Keep them in step with ROCKNIX's
`projects/ROCKNIX/packages/linux/package.mk` and the H700 U-Boot and TF-A
packages for that commit.

## Known gaps

- Deep sleep: ROCKNIX's H700 suspend stub (TF-A patch plus SRAM stub) isn't
  ported, so suspend is s2idle only.
- The root partition doesn't grow to fill the SD card yet.
- No ROMs/saves partition, frontend, RetroArch, or emulator cores yet.
- All `apt` installs must happen before the Containerfile's final layout step,
  which removes `/var` (and with it the dpkg database).
