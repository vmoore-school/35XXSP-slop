# bootc image for the Anbernic RG35XX-SP (Allwinner H700), based on Debian.
#
# Kernel, TF-A and U-Boot are cross-compiled natively on the build host
# ($BUILDPLATFORM); only package installation and the bootc build run as arm64.
ARG DEBIAN_SUITE=testing

# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM docker.io/library/debian:${DEBIAN_SUITE} AS cross

# Native gcc on an arm64 host already provides aarch64-linux-gnu-* tools.
RUN sed -i 's/^Components: main$/Components: main non-free-firmware/' /etc/apt/sources.list.d/debian.sources && \
    if [ "$(dpkg --print-architecture)" != arm64 ]; then cross_gcc=gcc-aarch64-linux-gnu; fi && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      bc bison build-essential ca-certificates cpio curl device-tree-compiler \
      firmware-realtek flex ${cross_gcc:-} git kmod libelf-dev \
      libgnutls28-dev libssl-dev python3 python3-dev python3-libfdt python3-pyelftools \
      python3-setuptools rsync swig u-boot-tools uuid-dev xz-utils zstd && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY vendor/ vendor/

# ---------------------------------------------------------------------------
FROM cross AS kernel
COPY build/kernel.sh build/kernel.config build/
RUN build/kernel.sh /out

# ---------------------------------------------------------------------------
FROM cross AS bootloader
COPY build/u-boot.sh build/
COPY disk/boot.cmd disk/
RUN build/u-boot.sh /out

# ---------------------------------------------------------------------------
FROM docker.io/library/debian:${DEBIAN_SUITE} AS bootc-builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates cargo git go-md2man libclang-dev libglib2.0-dev libostree-dev \
      libselinux1-dev libssl-dev libzstd-dev make pkgconf rustc && \
    rm -rf /var/lib/apt/lists/*
COPY build/bootc.sh /src/build/
RUN /src/build/bootc.sh /out

# ---------------------------------------------------------------------------
FROM docker.io/library/debian:${DEBIAN_SUITE} AS system

RUN sed -i 's/^Components: main$/Components: main non-free-firmware/' /etc/apt/sources.list.d/debian.sources && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      systemd systemd-sysv systemd-resolved systemd-timesyncd udev dbus \
      ostree ostree-boot dracut skopeo podman bubblewrap zstd \
      e2fsprogs dosfstools fdisk util-linux kmod \
      iwd iw iproute2 firmware-realtek \
      openssh-server ca-certificates less nano fastfetch && \
    rm -rf /var/lib/apt/lists/*

COPY --from=bootc-builder /out/ /
COPY --from=kernel /out/usr/ /usr/
# The bootloader is written outside the ostree deployment (raw at 256 KiB and
# on the ESP), but shipping it in the image keeps it versioned with the OS.
COPY --from=bootloader /out/ /usr/lib/rg35xxsp/bootloader/
COPY system/ /

RUN systemctl enable systemd-networkd systemd-resolved systemd-timesyncd iwd ssh \
      rg35xxsp-esp-provision.service rg35xxsp-esp-logs.timer && \
    systemctl mask systemd-firstboot.service && \
    rm -f /etc/ssh/ssh_host_*_key* && \
    echo uninitialized > /etc/machine-id && \
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime

RUN kver="$(ls /usr/lib/modules)" && \
    dracut --force --kver "${kver}" "/usr/lib/modules/${kver}/initramfs.img"

# ostree/bootc root layout: state lives under /var, /usr is the image.
RUN rm -rf /boot /home /root /usr/local /srv /opt /mnt /var && \
    mkdir -p /sysroot /boot /usr/lib/ostree /var && \
    ln -sT sysroot/ostree /ostree && \
    ln -sT var/roothome /root && \
    ln -sT var/srv /srv && \
    ln -sT var/opt /opt && \
    ln -sT var/mnt /mnt && \
    ln -sT var/home /home && \
    ln -sT ../var/usrlocal /usr/local && \
    printf 'd /var/%s 0755 root root -\n' opt home srv mnt usrlocal > /usr/lib/tmpfiles.d/bootc-base-dirs.conf && \
    printf 'd /var/roothome 0700 root root -\nd /run/media 0755 root root -\n' >> /usr/lib/tmpfiles.d/bootc-base-dirs.conf && \
    sed -i 's|^HOME=.*|HOME=/var/home|' /etc/default/useradd

LABEL containers.bootc=1
RUN bootc container lint
