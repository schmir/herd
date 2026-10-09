--dirty and --clean keep only the repositories whose working copy has
changes, or has none.

  $ . "$TESTDIR/setup.sh"
  $ two_repos
  $ cd "$HOME"
  $ herd clone >/dev/null

Nothing has changed yet.

  $ herd list --dirty
  No repository is left of the 2 selected by --dirty
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
  No repository is left of the 2 selected by --clean
  $ herd list --dirty
  $ROOT/home/src/api\t$ROOT/origins/api (esc)

clone does not take them.

  $ herd clone --dirty 2>&1 | head -1
  usage error: unknown option dirty

-f with a shell command keeps the repositories where it exits 0, run in each
one. Several must all hold, and they combine with --dirty and --clean.

  $ herd clone >/dev/null
  $ echo change >src/api/notes
  $ touch src/web/marker
  $ herd list -f 'test -f notes'
  $ROOT/home/src/api\t$ROOT/origins/api (esc)
  $ herd list -f 'test -f marker' -f 'test ! -f notes'
  $ROOT/home/src/web\t$ROOT/origins/web (esc)
  $ herd list -f 'test -f notes' --clean
  No repository is left of the 2 selected by --clean and -f
  $ herd run -f 'test -f marker' --show-output always git rev-parse --abbrev-ref HEAD
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | stdout
  |   main
  1 succeeded, 0 failed, 0 skipped, 0 not checked out

A command that exits non-zero drops everything, which is said.

  $ herd list -f false
  No repository is left of the 2 selected by -f

A single word that is no program is most likely a mistyped filter name, and
is said so before anything runs.

  $ herd run -f no-such-command-here true
  "no-such-command-here" is neither a configured filter nor a command; no filters are configured
  [1]

A command the shell cannot run is a mistake, not a repository that does not
match.

  $ herd run -j 1 -f 'no-such-command-here now' true
  .*/home/src/api: cannot run "no-such-command-here now": .*not found (re)
  .*/home/src/web: cannot run "no-such-command-here now": .*not found (re)
  Selection error: cannot check 2 repositories
  [1]

A filter in :filters can stand for a shell command, and -f then takes its
name. A name that no filter defines is still a command of its own.

  $ cat >"$CONFIG/config.jdn" <<'JDN'
  > {:filters {"has-notes" {:sh "test -f notes"}
  >            "no-notes"  {:sh "test ! -f notes"}}}
  > JDN
  $ herd list -f has-notes
  $ROOT/home/src/api\t$ROOT/origins/api (esc)
  $ herd list -f no-notes -f 'test -f marker'
  $ROOT/home/src/web\t$ROOT/origins/web (esc)

A word that is neither says which filters there are.

  $ herd list -f has-nots
  "has-nots" is neither a configured filter nor a command; configured filters are "has-notes", "no-notes"
  [1]

clone cannot run commands in checkouts that are not there yet, so it only
takes filters that narrow a list.

  $ herd clone -f has-notes
  usage error: clone can only use the JMESPath filters in :filters, and "has-notes" is not one
  [1]
  $ herd clone -f 'test -f notes'
  usage error: clone can only use the JMESPath filters in :filters, and "test -f notes" is not one
  [1]
