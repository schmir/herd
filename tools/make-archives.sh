#!/usr/bin/env bash
# Pack the release archives of herd.
# Usage: make-archives.sh TAG BINARIES OUT [PLATFORM...]
#
# BINARIES holds PLATFORM/herd for each platform. Without a PLATFORM, each of
# those is packed. OUT gets herd-TAG-PLATFORM.tar.gz for each platform and
# herd-TAG-SHA256SUMS, the checksums of those archives. The files that OUT
# holds for TAG from an earlier run are removed first, so that the checksum
# file lists only the archives of this run.
#
# An archive holds one directory with the name of the archive without
# .tar.gz. It unpacks into a directory of its own, and the archives of two
# platforms do not unpack into the same one. The binary in it keeps the name
# herd. The documentation and the license files go with it: README.md,
# REFERENCE.md, LICENSE and THIRD-PARTY-NOTICES. herd self-update reads this
# layout.
set -euo pipefail
tag=$1
binaries=$2
out=$3
shift 3
root=$(cd "$(dirname "$0")/.." && pwd)

# The options that make an archive reproducible are those of GNU tar.
if ! tar --version 2>/dev/null | grep -q 'GNU tar'; then
    echo "make-archives.sh needs GNU tar as tar; the devshell provides it" >&2
    exit 1
fi

platforms=("$@")
if ((${#platforms[@]} == 0)); then
    for binary in "$binaries"/*/herd; do
        [[ -f "$binary" ]] || continue
        platforms+=("$(basename "$(dirname "$binary")")")
    done
fi
if ((${#platforms[@]} == 0)); then
    echo "no PLATFORM/herd in $binaries" >&2
    exit 1
fi

# The same binary gives the same archive: the files get the time of the
# commit, and gzip -n leaves out the name and time it would otherwise record.
mtime=$(git -C "$root" log -1 --format=%ct)

mkdir -p "$out"
rm -f "$out/herd-$tag-"*.tar.gz "$out/herd-$tag-SHA256SUMS"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
for platform in "${platforms[@]}"; do
    top="herd-$tag-$platform"
    mkdir "$stage/$top"
    install -m 755 "$binaries/$platform/herd" "$stage/$top/herd"
    for file in README.md REFERENCE.md LICENSE THIRD-PARTY-NOTICES; do
        install -m 644 "$root/$file" "$stage/$top/$file"
    done
    # Owner and group 0 keep the account that ran this out of the archive.
    # The sort makes the order of the files the same on every file system.
    tar -cf - --sort=name --mtime="@$mtime" --owner=0 --group=0 --numeric-owner \
        -C "$stage" "$top" | gzip -n >"$out/$top.tar.gz"
done
# The tag in the name gives each release a checksum file of its own name.
(cd "$out" && sha256sum -- "herd-$tag-"*.tar.gz >"herd-$tag-SHA256SUMS")
