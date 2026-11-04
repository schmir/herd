herd self-update replaces the herd it runs as with the latest release, or
the release a version names.

  $ . "$TESTDIR/setup.sh"

The update replaces the file herd runs from, so a copy stands in for the
binary under test, and the link setup.sh makes leads to it.

  $ cp "$HERD" "$ROOT/herd"
  $ ln -sf "$ROOT/herd" "$ROOT/bin/herd"
  $ version=$(herd --version | cut -d' ' -f2)

Releases laid out on disk as the GitHub API describes them, each described
in $ROOT/api/tags/TAG, and the one released last in $ROOT/api/latest too.
Each has an archive for this platform that holds a herd saying what it is.

  $ case "$(uname -s)-$(uname -m)" in
  >     Linux-x86_64) platform=linux-x86_64 ;;
  >     Linux-aarch64 | Linux-arm64) platform=linux-aarch64 ;;
  >     Darwin-arm64) platform=macos-arm64 ;;
  >     Darwin-x86_64) platform=macos-x86_64 ;;
  >     OpenBSD-amd64) platform=openbsd-amd64 ;;
  >     OpenBSD-arm64) platform=openbsd-arm64 ;;
  >     FreeBSD-amd64) platform=freebsd-amd64 ;;
  >     FreeBSD-arm64 | FreeBSD-aarch64) platform=freebsd-arm64 ;;
  > esac
  $ release() {
  >     tag=$1
  >     body=${2:-"case \$1 in --version) echo \"herd $tag\" ;; *) echo \"new herd $tag\" ;; esac"}
  >     dir="$ROOT/release/$tag"
  >     mkdir -p "$dir/stage"
  >     printf '#!/bin/sh\n%s\n' "$body" >"$dir/stage/herd"
  >     chmod 755 "$dir/stage/herd"
  >     archive="herd-$tag-$platform.tar.gz"
  >     tar -czf "$dir/$archive" -C "$dir/stage" herd
  >     (cd "$dir" && { sha256sum "$archive" 2>/dev/null || shasum -a 256 "$archive"; } \
  >         >"herd-$tag-SHA256SUMS")
  >     mkdir -p "$ROOT/api/tags"
  >     cat >"$ROOT/api/tags/$tag" <<EOF
  > {"tag_name": "$tag",
  >  "assets": [{"name": "$archive", "browser_download_url": "file://$dir/$archive"},
  >             {"name": "herd-$tag-SHA256SUMS",
  >              "browser_download_url": "file://$dir/herd-$tag-SHA256SUMS"}]}
  > EOF
  >     cp "$ROOT/api/tags/$tag" "$ROOT/api/latest"
  > }
  $ export HERD_RELEASES_URL="file://$ROOT/api"

A herd that is the latest release already is left alone.

  $ release "$version"
  $ herd self-update
  herd \S+ is already the latest release (re)

An archive that does not match its checksum fails, and the herd stays.

  $ release v99.0.0
  $ sums="$ROOT/release/v99.0.0/herd-v99.0.0-SHA256SUMS"
  $ sed 's/^[0-9a-f]*/0000/' "$sums" >"$sums.new" && mv "$sums.new" "$sums"
  $ herd self-update
  self-update failed: herd-v99.0.0-.*\.tar\.gz does not match its checksum in herd-v99.0.0-SHA256SUMS (re)
  [1]
  $ herd --version
  herd \S+ (re)
  $ test "$(herd --version)" = "herd $version" && echo unchanged
  unchanged

A release without an archive for this platform fails as well.

  $ cat >"$ROOT/api/latest" <<EOF
  > {"tag_name": "v99.0.0", "assets": []}
  > EOF
  $ herd self-update
  self-update failed: release v99.0.0 has no herd-v99.0.0-.*\.tar\.gz (re)
  [1]

A herd that does not run here, or that is not the release it claims to
be, is caught before it replaces the one that runs.

  $ release v99.0.0 'echo "Bad CPU type in executable" >&2; exit 126'
  $ herd self-update
  self-update failed: the herd in herd-v99.0.0-.*\.tar\.gz does not run here: Bad CPU type in executable (re)
  [1]
  $ release v99.0.0 'exit 1'
  $ herd self-update
  self-update failed: the herd in herd-v99.0.0-.*\.tar\.gz does not run here: it exited 1 (re)
  [1]
  $ release v99.0.0 'echo "herd v1.0.0"'
  $ herd self-update
  self-update failed: the herd in herd-v99.0.0-.*\.tar\.gz reports "herd v1.0.0", not herd v99.0.0 (re)
  [1]
  $ test "$(herd --version)" = "herd $version" && echo unchanged
  unchanged

A version names a release by its tag, with or without the v. One that is
not released, or that is not a tag at all, fails.

  $ herd self-update 42.0.0
  self-update failed: cannot find release v42.0.0: downloading file://\$ROOT/api/tags/v42.0.0 failed: curl: .* (re)
  [1]
  $ herd self-update ../latest
  self-update failed: "../latest" is not a release version
  [1]
  $ herd self-update 1 2
  usage error: herd self-update takes at most one version
  [1]

A herd that is the release named already is left alone.

  $ release "$version"
  $ herd self-update "$version"
  herd \S+ is already installed (re)

A version installs its release even when a later one is the latest, and
a herd is replaced by an older release as by a newer one.

  $ release v98.0.0
  $ release v99.0.0
  $ herd self-update 98.0.0
  Updated herd \S+ to v98.0.0: \$ROOT/herd (re)
  $ herd
  new herd v98.0.0

The update replaces the file the link leads to, not the link, and leaves
nothing behind beside it.

  $ cp "$HERD" "$ROOT/herd"
  $ herd self-update
  Updated herd \S+ to v99.0.0: \$ROOT/herd (re)
  $ herd
  new herd v99.0.0
  $ test -L "$ROOT/bin/herd" && echo link
  link
  $ ls -a "$ROOT" | grep herd-update || echo none
  none
