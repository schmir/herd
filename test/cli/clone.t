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
  ✗ $ROOT/home/src/docs
  ! holds something that is not a repository
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
  ✗ $ROOT/home/src/docs
  ! holds something that is not a repository
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

Failures read as those of herd run do: each is a block headed by its path and
exit status, what the VCS wrote to stdout behind | and to stderr behind !, with
a blank line between blocks. --show-output picks what is shown, as it does there.

  $ cat >"$ROOT/bin/git" <<'EOF'
  > #!/bin/sh
  > echo out
  > echo err >&2
  > exit 128
  > EOF
  $ chmod +x "$ROOT/bin/git"
  $ rm -rf src/docs
  $ herd clone -j 1 2>&1 | grep -v '^.* cloned,'
  \xe2\x9c\x97 $ROOT/home/src/docs (exit 128) (esc)
  | out
  ! err
  
  \xe2\x9c\x97 $ROOT/home/src/gone (exit 128) (esc)
  | out
  ! err
  $ herd clone -j 1 --show-output never -C src/docs
  0 cloned, 0 already checked out, 0 blocked, 1 failed
  [1]
  $ herd clone --show-output sometimes
  Invalid --show-output: expected "never", "on-failure", or "always"
  [1]
  $ rm "$ROOT/bin/git"

A clone that worked is named on a line of its own, set apart from the blocks
around it.

  $ cat >"$ROOT/bin/git" <<'EOF'
  > #!/bin/sh
  > for dest; do :; done
  > case "$dest" in
  > */."$FAIL".herd-clone) echo err >&2; exit 128 ;;
  > esac
  > mkdir -p "$dest/.git"
  > EOF
  $ chmod +x "$ROOT/bin/git"
  $ export FAIL=gone
  $ herd clone -j 1
  Clone complete: $ROOT/home/src/docs
  
  \xe2\x9c\x97 $ROOT/home/src/gone (exit 128) (esc)
  ! err
  1 cloned, 2 already checked out, 0 blocked, 1 failed
  [1]
  $ rm -rf src/docs
  $ export FAIL=docs
  $ herd clone -j 1
  \xe2\x9c\x97 $ROOT/home/src/docs (exit 128) (esc)
  ! err
  
  Clone complete: $ROOT/home/src/gone
  1 cloned, 2 already checked out, 0 blocked, 1 failed
  [1]
  $ unset FAIL
  $ rm -rf src/gone "$ROOT/bin/git"

--show-output always shows what a successful clone printed instead.

  $ cat >"$ROOT/bin/git" <<'EOF'
  > #!/bin/sh
  > for dest; do :; done
  > echo cloning
  > mkdir -p "$dest/.git"
  > EOF
  $ chmod +x "$ROOT/bin/git"
  $ herd clone -j 1 --show-output always -C src/docs
  \xe2\x9c\x93 $ROOT/home/src/docs (esc)
  | cloning
  1 cloned, 0 already checked out, 0 blocked, 0 failed
  $ rm -rf src/docs "$ROOT/bin/git"

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

ssh asks on the terminal even with standard input closed, which would hang a
clone nobody can answer, such as one of a host not known yet. Whichever VCS
runs it, ssh is told to fail instead.

  $ cat >"$ROOT/bin/ssh" <<EOF
  > #!/bin/sh
  > echo "\$SSH_ASKPASS_REQUIRE \$SSH_ASKPASS" >>"$ROOT/ssh.env"
  > exit 255
  > EOF
  $ chmod +x "$ROOT/bin/ssh"
  $ cat >"$CONFIG/ssh.json" <<EOF
  > [{"path": "src/over-git", "ssh_url": "git@example.invalid:over.git", "vcs": "git"},
  >  {"path": "src/over-jj", "ssh_url": "git@example.invalid:over.git", "vcs": "jj"}]
  > EOF
  $ herd clone -j 1 -C src/over-git > /dev/null
  [1]
  $ herd clone -j 1 -C src/over-jj > /dev/null
  [1]
  $ cat "$ROOT/ssh.env"
  force false
  force false
