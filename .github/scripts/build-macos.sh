#!/bin/sh
# Build a herd binary on macOS.
#
# There is no musl here and no static libSystem, so the binary links
# dynamically against the system libraries. MACOSX_DEPLOYMENT_TARGET keeps it
# runnable on older macOS than the builder.
set -eux

# Janet 1.41.2 and jpm 1.2.0, named by the commit each tag pointed at rather
# than by the tag itself. A commit id is a hash of the tree it names, so this
# is the same source on every build, whatever later becomes of the tag.
JANET_COMMIT=0fea20c82182fe661f75b00a8889d801fe2d79b6
JPM_COMMIT=907daf191ad3f1cf7e5190ec4f44eb29cd54ba21

export MACOSX_DEPLOYMENT_TARGET=11.0

REPO="$PWD"

# Fetch exactly one commit into a directory of its own. Asking for the commit
# rather than a branch or tag is what makes this reproducible: the server has
# no say in which revision the name resolves to.
fetch_commit() {
  git init -q "$3"
  git -C "$3" remote add origin "$1"
  git -C "$3" fetch -q --depth 1 origin "$2"
  git -C "$3" checkout -q FETCH_HEAD
}

# Build janet and jpm from source rather than via Homebrew, so the toolchain
# matches the Linux job and the versions are pinned in one place.
WORK="$(mktemp -d)"
fetch_commit https://github.com/janet-lang/janet.git "$JANET_COMMIT" "$WORK/janet"
cd "$WORK/janet"
make -j"$(sysctl -n hw.ncpu)"
sudo make install

fetch_commit https://github.com/janet-lang/jpm.git "$JPM_COMMIT" "$WORK/jpm"
cd "$WORK/jpm"
sudo janet bootstrap.janet

cd "$REPO"
jpm --local load-lockfile
jpm --local build
strip build/herd
