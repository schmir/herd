run, fetch and custom commands run in every checked-out repository. -j 1
keeps the output in configuration order.

  $ . "$TESTDIR/setup.sh"
  $ two_repos
  $ cd "$HOME"

Nothing is checked out yet, which is not a failure.

  $ herd run true
  0 succeeded, 0 failed, 0 skipped, 2 not checked out

  $ herd clone -C src/api > /dev/null

A successful command stays quiet by default.

  $ herd run git rev-parse --abbrev-ref HEAD
  1 succeeded, 0 failed, 0 skipped, 1 not checked out

  $ herd clone > /dev/null
  $ herd run -j 1 --show-output always git rev-parse --abbrev-ref HEAD
  \xe2\x9c\x93 $ROOT/home/src/api (esc)
  | stdout
  |   main
  
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | stdout
  |   main
  2 succeeded, 0 failed, 0 skipped, 0 not checked out

The command runs in the repository.

  $ herd run -j 1 --show-output always pwd
  \xe2\x9c\x93 $ROOT/home/src/api (esc)
  | stdout
  |   $ROOT/home/src/api
  
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | stdout
  |   $ROOT/home/src/web
  2 succeeded, 0 failed, 0 skipped, 0 not checked out

A failing command is reported with its exit status and fails herd.

  $ herd run -j 1 sh -c 'echo oops >&2; exit 3'
  \xe2\x9c\x97 $ROOT/home/src/api (exit 3) (esc)
  | stderr
  |   oops
  
  \xe2\x9c\x97 $ROOT/home/src/web (exit 3) (esc)
  | stderr
  |   oops
  0 succeeded, 2 failed, 0 skipped, 0 not checked out
  [1]

never hides even a failure.

  $ herd run --show-output never false
  0 succeeded, 2 failed, 0 skipped, 0 not checked out
  [1]

  $ herd fetch
  2 succeeded, 0 failed, 0 skipped, 0 not checked out

A custom command is listed in --help and runs like run, with its own
default for --show-output.

  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:commands
  >  {"branch" {:command "git rev-parse --abbrev-ref HEAD"
  >             :description "Print the branch."
  >             :show-output "always"}
  >   "jj-only" {:command-jj "jj st"
  >              :description "Needs jj."}}}
  > EOF
  $ herd --help | grep -E '^  (branch|jj-only) '
    branch    Print the branch.
    jj-only   Needs jj.
  $ herd branch -C src/web
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | stdout
  |   main
  1 succeeded, 0 failed, 0 skipped, 0 not checked out

A Git checkout has no command in jj-only, so it is skipped.

  $ herd jj-only
  0 succeeded, 0 failed, 2 skipped, 0 not checked out

A directory holding something that is not a repository is not a checkout,
so nothing runs or fetches there.

  $ cat >"$CONFIG/more.json" <<'JSON'
  > [{"path": "src/docs", "ssh_url": "unused", "vcs": "git"}]
  > JSON
  $ mkdir -p src/docs && touch src/docs/notes
  $ herd run -C src/docs touch ran
  0 succeeded, 0 failed, 0 skipped, 1 not checked out
  $ ls src/docs
  notes
  $ herd fetch -C src/docs
  0 succeeded, 0 failed, 0 skipped, 1 not checked out
