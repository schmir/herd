clone checks out what is missing and leaves the rest alone. -j 1 keeps the
output in configuration order.

  $ . "$TESTDIR/setup.sh"
  $ two_repos
  $ cd "$HOME"

  $ herd clone -j 1
  Clone complete: $ROOT/home/src/api
  Clone complete: $ROOT/home/src/web
  2 cloned, 0 already checked out, 0 failed
  $ git -C src/api log --format=%s
  init

The repository's "vcs" asked for plain Git, so there is no .jj.

  $ ls -A src/web
  .git

A second clone finds everything checked out.

  $ herd clone
  0 cloned, 2 already checked out, 0 failed

An existing non-empty directory counts as checked out, whatever it holds.

  $ origin docs
  $ cat >"$CONFIG/more.json" <<EOF
  > [{"path": "src/docs", "ssh_url": "$ROOT/origins/docs", "vcs": "git"},
  >  {"path": "src/gone", "ssh_url": "$ROOT/origins/gone", "vcs": "git"}]
  > EOF
  $ mkdir -p src/docs && touch src/docs/notes
  $ herd clone -j 1 -C src/docs
  0 cloned, 1 already checked out, 0 failed

A clone that fails is counted, and fails the command.

  $ herd clone -j 1 -C src/gone > out
  [1]
  $ tail -1 out
  0 cloned, 0 already checked out, 1 failed
  $ test -e src/gone
  [1]
