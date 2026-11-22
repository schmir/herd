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
  ok\t$ROOT/home/src/api\t$ROOT/origins/api (esc)
  $ touch src/web/marker
  $ herd list -f has-marker
  ok\t$ROOT/home/src/api\t$ROOT/origins/api (esc)
  ok\t$ROOT/home/src/web\t$ROOT/origins/web (esc)
  $ herd list -f platform -f has-marker
  ok\t$ROOT/home/src/api\t$ROOT/origins/api (esc)


A named command filter takes arguments after a colon. They are its $1, $2 and
so on. Here nothing but the first checkout has both files.

  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:filters {"has-file" {:sh "test -f \"$1\" && test -f \"${2:-$1}\""}}}
  > EOF
  $ touch src/api/a src/api/b src/web/a
  $ herd list -f has-file:::a:::b
  ok\t$ROOT/home/src/api\t$ROOT/origins/api (esc)
  $ herd list -f has-file:a
  ok\t$ROOT/home/src/api\t$ROOT/origins/api (esc)
  ok\t$ROOT/home/src/web\t$ROOT/origins/web (esc)
  $ herd list -f 'has-file:a b'
  ok\t$ROOT/home/src/api\t$ROOT/origins/api (esc)

A longer run of colons lets one argument hold a space, and -x passes the
arguments on as -f does. Only the second checkout has a file named "a b".

  $ touch "src/web/a b"
  $ herd list -x 'has-file:::a b'
  ok\t$ROOT/home/src/api\t$ROOT/origins/api (esc)
  $ herd list -f 'has-file:a b'
  ok\t$ROOT/home/src/api\t$ROOT/origins/api (esc)
  $ rm "src/web/a b"
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:filters {"platform" {:jp "[?group=='platform']"}
  >            "has-marker" {:sh "test -f marker"}}}
  > EOF
  $ rm src/api/a src/api/b src/web/a


-x keeps the repositories a filter leaves out, of either kind, and of a
command given in place of a name.

  $ rm src/web/marker
  $ herd list -x has-marker
  ok\t$ROOT/home/src/web\t$ROOT/origins/web (esc)
  $ herd list -x 'test -f marker'
  ok\t$ROOT/home/src/web\t$ROOT/origins/web (esc)
  $ herd list -x platform
  ok\t$ROOT/home/src/web\t$ROOT/origins/web (esc)
  $ herd list --exclude platform -x has-marker
  ok\t$ROOT/home/src/web\t$ROOT/origins/web (esc)
  $ herd list -f platform -x has-marker
  No repository is left of the 1 selected by -x

clone has no checkout to run an excluded command in either.

  $ herd clone -x has-marker
  usage error: clone can only use the JMESPath filters in :filters, and "has-marker" is not one
  [1]
