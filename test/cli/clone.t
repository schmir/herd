clone checks out what is missing and leaves the rest alone. -j 1 keeps the
output in configuration order.

  $ . "$TESTDIR/setup.sh"
  $ two_repos
  $ cd "$HOME"

  $ herd clone -j 1
  Clone complete: $ROOT/home/src/api
  Clone complete: $ROOT/home/src/web
  2 cloned, 0 already checked out, 0 blocked, 0 failed
  $ git -C src/api log --format=%s
  init

The repository's "vcs" asked for plain Git, so there is no .jj.

  $ ls -A src/web
  .git

A second clone finds everything checked out.

  $ herd clone
  0 cloned, 2 already checked out, 0 blocked, 0 failed

A directory holding something that is not a repository blocks the clone,
which is named and fails the command, and is left as it is.

  $ origin docs
  $ cat >"$CONFIG/more.json" <<EOF
  > [{"path": "src/docs", "ssh_url": "$ROOT/origins/docs", "vcs": "git"},
  >  {"path": "src/gone", "ssh_url": "$ROOT/origins/gone", "vcs": "git"}]
  > EOF
  $ mkdir -p src/docs && touch src/docs/notes
  $ herd clone -j 1 -C src/docs
  Clone blocked: $ROOT/home/src/docs holds something that is not a repository
  0 cloned, 0 already checked out, 1 blocked, 0 failed
  [1]
  $ ls src/docs
  notes

An empty directory is cloned into.

  $ rm src/docs/notes
  $ herd clone -j 1 -C src/docs
  Clone complete: $ROOT/home/src/docs
  1 cloned, 0 already checked out, 0 blocked, 0 failed

A dangling symbolic link leads nowhere, but it is still in the way.

  $ rm -rf src/docs && ln -s nowhere src/docs
  $ herd list --status -C src/docs
  blocked\t$ROOT/home/src/docs\t$ROOT/origins/docs (esc)
  $ herd clone -j 1 -C src/docs
  Clone blocked: $ROOT/home/src/docs holds something that is not a repository
  0 cloned, 0 already checked out, 1 blocked, 0 failed
  [1]
  $ readlink src/docs
  nowhere

A clone that fails is counted, and fails the command. It leaves nothing
behind, not even the hidden directory beside the checkout it was cloned in.

  $ herd clone -j 1 -C src/gone > out
  [1]
  $ tail -1 out
  0 cloned, 0 already checked out, 0 blocked, 1 failed
  $ test -e src/gone
  [1]
  $ ls -A src
  api
  docs
  web

A clone that dies half-written, as one killed or caught by a crash does,
leaves nothing that passes for a checkout, nor anything beside it, and the
next clone starts over.

  $ cat >"$ROOT/bin/git" <<'EOF'
  > #!/bin/sh
  > for dest; do :; done
  > mkdir -p "$dest/.git"
  > kill -9 $$
  > EOF
  $ chmod +x "$ROOT/bin/git"
  $ rm src/docs
  $ herd clone -j 1 -C src/docs > /dev/null
  [1]
  $ herd list --status -C src/docs
  missing\t$ROOT/home/src/docs\t$ROOT/origins/docs (esc)
  $ ls -A src
  api
  web
  $ rm "$ROOT/bin/git"
  $ herd clone -j 1 -C src/docs
  Clone complete: $ROOT/home/src/docs
  1 cloned, 0 already checked out, 0 blocked, 0 failed
