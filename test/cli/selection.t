Which repositories a working location selects. The paths are absolute and
need not exist, since list prints what is configured.

  $ . "$TESTDIR/setup.sh"
  $ cat >"$CONFIG/repos.json" <<'EOF'
  > [{"path": "/srv/foo", "ssh_url": "foo"},
  >  {"path": "/srv/foo/bar", "ssh_url": "bar"},
  >  {"path": "/srv/foobar", "ssh_url": "foobar"},
  >  {"path": "/srv/other", "ssh_url": "other"}]
  > EOF
  $ echo '{:checkouts [{:from "repos.json" :anchor "/srv"}]}' >"$CONFIG/config.jdn"

A directory selects everything below it.

  $ herd list -C /srv/foo
  /srv/foo\tfoo (esc)
  /srv/foo/bar\tbar (esc)

  $ herd list -C /srv
  /srv/foo\tfoo (esc)
  /srv/foo/bar\tbar (esc)
  /srv/foobar\tfoobar (esc)
  /srv/other\tother (esc)

A path inside a working copy selects that repository, however deep, and
nested repositories both hold a path below them.

  $ herd list -C /srv/foo/deep/inside
  /srv/foo\tfoo (esc)

  $ herd list -C /srv/foo/bar/x
  /srv/foo\tfoo (esc)
  /srv/foo/bar\tbar (esc)

Matching is by whole path component, not by string prefix.

  $ herd list -C /srv/fo
  None of the configured repositories associated with an anchor containing /srv/fo are beneath it or hold it; use -a/--all-anchors to consider every anchor

  $ herd list -C /srv/foobar
  /srv/foobar\tfoobar (esc)

Trailing slashes and unnormalised paths mean what they look like.

  $ herd list -C /srv/foo/
  /srv/foo\tfoo (esc)
  /srv/foo/bar\tbar (esc)

  $ herd list -C /srv/foo//
  /srv/foo\tfoo (esc)
  /srv/foo/bar\tbar (esc)

  $ herd list -C /srv/foo/../foo
  /srv/foo\tfoo (esc)
  /srv/foo/bar\tbar (esc)

The filesystem root is in no anchor, unless every anchor is considered.

  $ herd list -C /
  No configuration anchor contains /; use -a/--all-anchors to consider every anchor

  $ herd list -a -C /
  /srv/foo\tfoo (esc)
  /srv/foo/bar\tbar (esc)
  /srv/foobar\tfoobar (esc)
  /srv/other\tother (esc)

Nested anchors: a location takes repositories from every anchor that
contains it, and an anchor does not contain its parent directory.

  $ cat >"$CONFIG/repos.json" <<'EOF'
  > [{"path": "/work/one", "ssh_url": "one"},
  >  {"path": "/work/team/parent", "ssh_url": "parent"},
  >  {"path": "/work/team/shared", "ssh_url": "shared"}]
  > EOF
  $ cat >"$CONFIG/team.json" <<'EOF'
  > [{"path": "/work/team/two", "ssh_url": "two"},
  >  {"path": "/work/team/shared", "ssh_url": "shared"}]
  > EOF
  $ cat >"$CONFIG/other.json" <<'EOF'
  > [{"path": "/work/team/unrelated", "ssh_url": "unrelated"}]
  > EOF
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:checkouts [{:from "repos.json" :anchor "/work"}
  >              {:from "team.json" :anchor "/work/team"}
  >              {:from "other.json" :anchor "/other"}]}
  > EOF

  $ herd list -C /work/team
  /work/team/parent\tparent (esc)
  /work/team/shared\tshared (esc)
  /work/team/two\ttwo (esc)

  $ herd list -C /work
  /work/one\tone (esc)
  /work/team/parent\tparent (esc)
  /work/team/shared\tshared (esc)

  $ herd list -a -C /work/team
  /work/team/unrelated\tunrelated (esc)
  /work/team/parent\tparent (esc)
  /work/team/shared\tshared (esc)
  /work/team/two\ttwo (esc)

  $ herd list -C /work/team/parent/deep
  /work/team/parent\tparent (esc)

Configured paths and the working location may reach one directory through
different symlinks, so both are resolved before they are compared.

  $ rm "$CONFIG"/*.json "$CONFIG/config.jdn"
  $ mkdir -p real/work/repo
  $ ln -s real link
  $ cat >"$CONFIG/repos.json" <<EOF
  > [{"path": "$ROOT/link/work/repo", "ssh_url": "repo"},
  >  {"path": "$ROOT/link/work/absent", "ssh_url": "absent"}]
  > EOF
  $ echo "{:checkouts [{:from \"repos.json\" :anchor \"$ROOT/link/work\"}]}" \
  >   >"$CONFIG/config.jdn"

  $ herd list -C real/work
  $ROOT/link/work/repo\trepo (esc)
  $ROOT/link/work/absent\tabsent (esc)

  $ herd list -C real/work/repo
  $ROOT/link/work/repo\trepo (esc)

  $ herd list -C link/work/repo
  $ROOT/link/work/repo\trepo (esc)

A location reached through a link does not make an unrelated anchor
contain it.

  $ mkdir elsewhere
  $ herd list -C elsewhere
  No configuration anchor contains elsewhere; use -a/--all-anchors to consider every anchor
