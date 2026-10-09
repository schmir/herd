A jj working copy is dirty when its commit is not empty.

  $ command -v jj > /dev/null || exit 80
  $ . "$TESTDIR/setup.sh"
  $ cd "$HOME"
  $ mkdir src
  $ jj git init src/plain >/dev/null 2>&1
  $ jj git init src/edited >/dev/null 2>&1
  $ cat >"$CONFIG/repos.json" <<'JSON'
  > [{"path": "src/plain", "ssh_url": "unused", "vcs": "jj"},
  >  {"path": "src/edited", "ssh_url": "unused", "vcs": "jj"}]
  > JSON

  $ echo change >src/edited/file
  $ herd list --dirty
  $ROOT/home/src/edited\tunused (esc)
  $ herd list --clean
  $ROOT/home/src/plain\tunused (esc)
