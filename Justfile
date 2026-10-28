image := env("IMAGE", "localhost/rg35xxsp-bootc:latest")
# Image reference the installed system will `bootc upgrade` from.
target_imgref := env("TARGET_IMGREF", image)
output := justfile_directory() / "output"

# bootc install needs the image in root's container storage, so everything
# that touches the image runs as root (PODMAN="pkexec podman" also works).
podman := env("PODMAN", "sudo podman")
# Only for smoke-testing the pipeline on x86 without emulation; such an image
# won't boot the device.
platform := env("PLATFORM", "linux/arm64")

# Build the bootc image (arm64; needs qemu-user binfmt on x86 hosts)
build:
    {{podman}} build --platform {{platform}} -t {{image}} .

# Build only the cross-compiled kernel or bootloader stage (native, fast to iterate)
build-stage stage:
    podman build --target {{stage}} -t rg35xxsp-{{stage}} .

# Create output/rg35xxsp.img from the built image. ram: lpddr4 or lpddr3
disk-image ram="lpddr4" size="3G":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "{{output}}"
    rm -f "{{output}}/rg35xxsp.img"
    truncate -s "{{size}}" "{{output}}/rg35xxsp.img"
    run() {
        {{podman}} run --rm --privileged --pid=host --platform {{platform}} \
            --security-opt label=type:unconfined_t \
            -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
            -v "{{output}}:/data" -v "{{justfile_directory()}}/disk:/disk:ro" \
            -e RAM="{{ram}}" -e ROOT_PASSWORD_HASH="${ROOT_PASSWORD_HASH:-}" \
            "{{image}}" "$@"
    }
    run bootc install to-disk --via-loopback --wipe --generic-image \
        --target-imgref "{{target_imgref}}" /data/rg35xxsp.img
    run /disk/finalize.sh /data/rg35xxsp.img
    echo "Wrote {{output}}/rg35xxsp.img"

# Write the disk image to an SD card, e.g. `just flash /dev/sdX`
flash device:
    sudo dd if="{{output}}/rg35xxsp.img" of="{{device}}" bs=4M conv=fsync status=progress

# Refresh vendor/rocknix from a ROCKNIX commit
vendor commit:
    scripts/vendor-rocknix.sh {{commit}}
