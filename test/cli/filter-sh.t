Filters can be shell commands as well as JMESPath, through jp for the latter.

  $ command -v jp > /dev/null || exit 80
  $ . "$TESTDIR/setup.sh"
  $ two_repos
  $ cd "$HOME"

A filter can also be a shell command, and the two kinds mix under -f. The
JMESPath ones narrow the lists first, and the commands run in what is left.

  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:filters {"platform" {:jp "[?group=='platform']"}
  >            "has-marker" {:sh "test -f marker"}}}
  > EOF
  $ herd clone >/dev/null
  $ touch src/api/marker
  $ herd list -f has-marker -f platform
  $ROOT/home/src/api\t$ROOT/origins/api (esc)
  $ touch src/web/marker
  $ herd list -f has-marker
  $ROOT/home/src/api\t$ROOT/origins/api (esc)
  $ROOT/home/src/web\t$ROOT/origins/web (esc)
  $ herd list -f platform -f has-marker
  $ROOT/home/src/api\t$ROOT/origins/api (esc)

