#!/usr/bin/env bash
# Build bootc from a pinned release tag and install it into $1.
# Debian does not package bootc, so this runs in an arm64 stage of the
# Containerfile (natively on an arm64 CI runner, emulated elsewhere).
set -euo pipefail

out="${1:?usage: $0 <outdir>}"
BOOTC_VERSION=v1.17.2

work="$(mktemp -d)"
git clone -q --depth 1 --branch "${BOOTC_VERSION}" https://github.com/bootc-dev/bootc.git "${work}/bootc"
# Skip man pages: generating them doubles an already long (emulated) build.
make -C "${work}/bootc" bin install install-ostree-hooks DISABLE_DOCS=1 DESTDIR="${out}"
rm -rf "${work}"
