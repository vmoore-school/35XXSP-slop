# Handoff: RG35XX-SP bootc image

State as of 2026-10-28. For picking this up on another machine. Read
`README.md` for how everything fits together; this file covers where things
stand and what to do next.

## Where things are

- **Repo:** https://github.com/vmoore-school/35XXSP-slop (`main`)
- **CI:** every push to `main` builds the arm64 image on GitHub's arm64
  runners (~20 min), pushes `ghcr.io/vmoore-school/rg35xxsp-bootc:latest`
  (public, pullable without login) and uploads the `rg35xxsp-lpddr4` disk
  image artifact. LPDDR3 only builds via "Run workflow" with `lpddr3` ticked.
- **Device:** pre-2026 RG35XX-SP, so LPDDR4. Standard SP panel (the
  default device tree works; v2-panel not needed). Card goes in TF1.

## What works (confirmed on hardware)

The image boots all the way to a login prompt: U-Boot, `boot.scr`, kernel,
display and systemd all come up. Also confirmed:

- `bootc upgrade` + reboot boots the new deployment: ostree's U-Boot backend
  rewrites `uEnv.txt` and `boot.scr` follows it.
- WiFi (rtw88, iwd, DHCPv4), `provision/wifi.txt` and `authorized_keys`, SSH.
- Display: DSI-1 at 640x480, 60 Hz, default SP panel device tree.
- Battery reporting (AXP717), GPU detected (Mali, sun50i-h616-mali).
- Gamepad: `rocknix_singleadc_joypad` loads and registers "H700 Gamepad"
  (needed `DEVICE=H700` when building the module). Individual buttons and
  sticks not exercised yet.

## Not yet checked

- Audio, button-by-button input, GPU rendering (panfrost/Mesa).
- `bootc rollback` and the `bootslot=2` override.

## Get a shell on the device

1. Flash the latest image (wipes the card):
   ```sh
   gh run list -R vmoore-school/35XXSP-slop --limit 1          # newest run id
   gh run download <run-id> -R vmoore-school/35XXSP-slop -n rg35xxsp-lpddr4
   zstd -d rg35xxsp-lpddr4.img.zst
   lsblk                                                         # find the card
   sudo dd if=rg35xxsp-lpddr4.img of=/dev/<card> bs=4M conv=fsync status=progress
   ```
   The image is 8 GiB, so the card must be larger than 8 GB.
2. Re-plug the card and open the `RG35XXSP` partition. In `provision/`:
   - create `wifi.txt`:
     ```
     ssid=<your network>
     password=<your password>
     ```
   - create `authorized_keys` with one public key per line. This is the
     desktop's (zirconium) key; add the laptop's (`cat ~/.ssh/id_ed25519.pub`)
     on a second line:
     ```
     ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFF2qaoQ6yNGFw76Lt6Jw/vj6vp5bXw1+6GJtphECARL valerie@zirconium
     ```
3. Boot the device. Once WiFi connects, the login screen shows its IP
   address. It's also in `logs/status.txt` on the card (written 45 s after
   boot) and in the router's device list as `rg35xxsp`.
4. `ssh root@rg35xxsp.local` (mDNS), or `ssh root@<ip>` if `.local` names
   don't resolve on your network.

Provisioning reruns every boot, so editing these files later and rebooting
updates WiFi and keys.

## First things to check once logged in

```sh
bootc status
iwctl station wlan0 show
cat /proc/device-tree/model
dmesg | grep -i -E "panfrost|joypad|axp|rtw88|codec"
systemctl --failed
```

Then test updates: push any change, wait for CI, then on the device run
`bootc upgrade && reboot`, and afterwards check `bootc status` shows the new
image booted. `cat /boot/loader/uEnv.txt` should list two deployments
(`kernel_image` and `kernel_image2`).

## Debugging a boot without a serial console

- **LED:** off entirely means U-Boot never ran. 1 blink means `boot.scr`
  started, 3 means the kernel is loading, 4 means the kernel is starting.
- **`uboot.log`** on the card: the last U-Boot stage reached.
- **`logs/`** on the card: journal, dmesg, previous boot's journal,
  `status.txt`.
- **`rg35xxsp.txt`** on the card: `fdtfile=` to swap the device tree,
  `bootslot=2` to boot the previous deployment.

## Lessons learned the hard way

- The H616 family boot ROM (H700 included) checks **256 KiB** after 8 KiB,
  not 128 KiB like older Allwinner chips. U-Boot lives at 256 KiB so the GPT
  stays intact.
- Desktops hide partitions typed "EFI System"; the ESP is retyped as
  Microsoft basic data. Code finds it by partition name `EFI-SYSTEM`; the
  volume label is `RG35XXSP`.
- bootc formats root ext4 with `-O verity`, so the kernel needs
  `CONFIG_FS_VERITY` (ROCKNIX's config doesn't set it).
- U-Boot's bundled pylibfdt doesn't build with Debian testing's swig and
  Python 3.14, so U-Boot builds with `NO_PYTHON=1`. bootc needs
  `libclang-dev`.
- No udev inside the install container, so `lsblk` shows no labels; use
  `blkid -p`.
- The user wants the **ostree backend**, not composefs-native (it breaks
  too often). ostree's own composefs mode is off too.
- No Claude `Co-Authored-By` trailers in commits.

## Backlog

1. Verify the remaining hardware (audio, buttons, GPU rendering) and
   `bootc rollback`.
2. Grow the root partition to fill the card on first boot, then shrink the
   image (~3 GiB) so flashing is faster.
3. ROMs/saves partition that survives reflashing and is readable from a PC.
4. Frontend + RetroArch + libretro cores (Debian packages RetroArch and many
   cores). Launch straight to KMS/DRM from a systemd unit, no desktop.
   Bring over muOS ideas, configs and themes where the licenses allow.
5. Deep sleep: port ROCKNIX's H700 suspend stub (TF-A patch + SRAM stub).
   Suspend is s2idle only for now.
6. Pin the Debian base by digest for reproducible builds.

## Leftover on the desktop (zirconium)

A loop device from an early local test is still attached: `/dev/loop0`,
mounted at `/tmp/tmp.QDCzd6hybU/{esp,root}`, backed by a deleted file. It's
harmless and goes away on reboot, or:
```sh
sudo umount /tmp/tmp.QDCzd6hybU/esp /tmp/tmp.QDCzd6hybU/root && sudo losetup -d /dev/loop0
```
