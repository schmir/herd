#!/usr/bin/env bash
# Build janet.c and janet.h from the pinned Janet commit into a directory.
# Usage: build-janet.sh DIR COMMIT
#
# Janet's boot step runs on the host, and its output is portable C, so this
# happens once per pinned commit. It is a script rather than a ninja command
# because the Nix hardening workaround below is not POSIX sh.
set -euo pipefail
dir=$1
commit=$2

if [[ -f "$dir/build/c/janet.c" && -f "$dir/build/janet.h" ]]; then
    exit 0
fi
rm -rf "$dir"
git init -q "$dir"
git -C "$dir" remote add origin https://github.com/janet-lang/janet.git
git -C "$dir" fetch -q --depth 1 origin "$commit"
git -C "$dir" checkout -q FETCH_HEAD
# Nix's compiler wrapper fortifies what it compiles, and Janet builds its
# bootstrap with -O0, which glibc warns about once per file. The bootstrap only
# writes janet.c, so build it without fortification. The wrapper reads its
# hardening from NIX_HARDENING_ENABLE, which nothing outside Nix reads.
hardening=" ${NIX_HARDENING_ENABLE-} "
hardening=${hardening// fortify3 / }
hardening=${hardening// fortify / }
NIX_HARDENING_ENABLE=$hardening \
    make -s -C "$dir" -j"$(getconf _NPROCESSORS_ONLN)" build/c/janet.c build/janet.h
