#!/bin/sh
# Build a fully static herd binary against musl, inside an Alpine container.
#
# Reproduce a release build locally from the repo root:
#   docker run --rm -v "$PWD:/src" -w /src alpine:3.21 sh /src/.github/scripts/build-musl.sh
#
# The result depends on no shared library at all, so one binary runs on any
# Linux distribution regardless of its glibc version.
set -eux

JANET_VERSION=1.41.2
JPM_VERSION=v1.2.0

REPO="$PWD"

apk add --no-cache build-base git curl

# Alpine packages neither janet nor jpm, so build both from source. They are
# plain C and a bootstrap script; this takes about a minute.
WORK="$(mktemp -d)"
cd "$WORK"
curl -fsSL "https://github.com/janet-lang/janet/archive/refs/tags/v${JANET_VERSION}.tar.gz" | tar xz
cd "janet-${JANET_VERSION}"
make -j"$(nproc)"
make install

cd "$WORK"
git clone --depth 1 --branch "$JPM_VERSION" https://github.com/janet-lang/jpm.git
cd jpm
janet bootstrap.janet

cd "$REPO"
jpm --local deps
# jpm's default :lflags is empty, so this only adds -static to the final link.
jpm --local build --lflags=-static
strip build/herd
