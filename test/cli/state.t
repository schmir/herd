--dirty and --clean keep only the repositories whose working copy has
changes, or has none.

  $ . "$TESTDIR/setup.sh"
  $ two_repos
  $ cd "$HOME"
  $ herd clone >/dev/null

Nothing has changed yet.

  $ herd list --dirty
  None of the 2 selected repositories is dirty
  $ herd list --clean
  $ROOT/home/src/api\t$ROOT/origins/api (esc)
  $ROOT/home/src/web\t$ROOT/origins/web (esc)

A file nobody added counts as a change.

  $ echo change >src/api/notes
  $ herd list --dirty
  $ROOT/home/src/api\t$ROOT/origins/api (esc)
  $ herd list --clean
  $ROOT/home/src/web\t$ROOT/origins/web (esc)

The commands that act take the same flags.

  $ herd run --dirty --show-output always git status --short
  \xe2\x9c\x93 $ROOT/home/src/api (esc)
  | stdout
  |   ?? notes
  1 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ herd diff --clean
  1 succeeded, 0 failed, 0 skipped, 0 not checked out

A repository that is not checked out is neither.

  $ rm -rf src/web
  $ herd list --dirty --clean
  usage error: --dirty and --clean exclude each other
  [1]
  $ herd list --clean
  None of the 2 selected repositories is clean
  $ herd list --dirty
  $ROOT/home/src/api\t$ROOT/origins/api (esc)

clone does not take them.

  $ herd clone --dirty 2>&1 | head -1
  usage error: unknown option dirty
