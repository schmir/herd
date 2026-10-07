list reads the origin of an extra jj repository through jj, without
snapshotting its working copy.

  $ command -v jj > /dev/null || exit 80
  $ . "$TESTDIR/setup.sh"
  $ cd "$HOME"
  $ echo '[]' >"$CONFIG/repos.json"

  $ mkdir src
  $ jj git init src/plain >/dev/null 2>&1
  $ jj git init src/linked >/dev/null 2>&1
  $ jj -R src/linked git remote add origin git@example.com:linked.git
  $ jj -R src/linked git remote add upstream git@example.com:upstream.git
  $ echo change >src/linked/file
  $ herd list --extra
  $ROOT/home/src/linked\tgit@example.com:linked.git (esc)
  $ROOT/home/src/plain\t (esc)
  $ jj -R src/linked --ignore-working-copy diff --summary
