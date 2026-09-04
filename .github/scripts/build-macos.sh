#!/bin/sh
# Build a herd binary on macOS.
#
# There is no musl here and no static libSystem, so the binary links
# dynamically against the system libraries. MACOSX_DEPLOYMENT_TARGET keeps it
# runnable on older macOS than the builder.
set -eux

JANET_VERSION=1.41.2
JPM_VERSION=v1.2.0

export MACOSX_DEPLOYMENT_TARGET=11.0

REPO="$PWD"

# Build janet and jpm from source rather than via Homebrew, so the toolchain
# matches the Linux job and the versions are pinned in one place.
WORK="$(mktemp -d)"
cd "$WORK"
curl -fsSL "https://github.com/janet-lang/janet/archive/refs/tags/v${JANET_VERSION}.tar.gz" | tar xz
cd "janet-${JANET_VERSION}"
make -j"$(sysctl -n hw.ncpu)"
sudo make install

cd "$WORK"
git clone --depth 1 --branch "$JPM_VERSION" https://github.com/janet-lang/jpm.git
cd jpm
sudo janet bootstrap.janet

cd "$REPO"
jpm --local deps
jpm --local build
strip build/herd
