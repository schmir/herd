list prints the selected repositories, and the working location decides
which those are.

  $ . "$TESTDIR/setup.sh"
  $ two_repos
  $ cd "$HOME"

The home is the default anchor, so from there every repository is listed,
checked out or not, as a path and a URL separated by a tab.

  $ herd list
  $ROOT/home/src/api\t$ROOT/origins/api (esc)
  $ROOT/home/src/web\t$ROOT/origins/web (esc)

Inside a repository, that repository is selected, however deep.

  $ mkdir -p src/api/lib/deep
  $ cd src/api/lib/deep
  $ herd list
  $ROOT/home/src/api\t$ROOT/origins/api (esc)
  $ cd "$HOME"

-C selects as if herd ran somewhere else.

  $ herd list -C src/web
  $ROOT/home/src/web\t$ROOT/origins/web (esc)

Outside every anchor nothing is selected, which is not an error, and the
message points at --all-anchors.

  $ herd list -C /
  No configuration anchor contains /; use -a/--all-anchors to consider every anchor
  $ herd list --all-anchors -C /
  $ROOT/home/src/api\t$ROOT/origins/api (esc)
  $ROOT/home/src/web\t$ROOT/origins/web (esc)

  $ mkdir elsewhere
  $ herd list -C elsewhere
  None of the configured repositories associated with an anchor containing elsewhere are beneath it or hold it; use -a/--all-anchors to consider every anchor

A :checkouts row anchors its list somewhere else, so the home no longer
contains the anchor.

  $ echo '{:checkouts [{:from "repos.json" :anchor "work"}]}' \
  >   >"$CONFIG/config.jdn"
  $ herd list
  No configuration anchor contains $ROOT/home; use -a/--all-anchors to consider every anchor
  $ herd list -C work
  $ROOT/home/work/src/api\t$ROOT/origins/api (esc)
  $ROOT/home/work/src/web\t$ROOT/origins/web (esc)

:strip-components drops leading path components before anchoring.

  $ echo '{:checkouts [{:from "repos.json" :strip-components 1}]}' \
  >   >"$CONFIG/config.jdn"
  $ herd list
  $ROOT/home/api\t$ROOT/origins/api (esc)
  $ROOT/home/web\t$ROOT/origins/web (esc)
