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
  | main
  
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | main
  2 succeeded, 0 failed, 0 skipped, 0 not checked out

The command runs in the repository.

  $ herd run -j 1 --show-output always pwd
  \xe2\x9c\x93 $ROOT/home/src/api (esc)
  | $ROOT/home/src/api
  
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | $ROOT/home/src/web
  2 succeeded, 0 failed, 0 skipped, 0 not checked out

-n stops once the command has run in that many repositories. The rest are
left alone, and herd says so.

  $ herd run -j 1 -n 1 --show-output always pwd
  \xe2\x9c\x93 $ROOT/home/src/api (esc)
  | $ROOT/home/src/api
  Stopped after 1 of 2 repositories
  1 succeeded, 0 failed, 0 skipped, 0 not checked out

A limit the selection does not reach changes nothing.

  $ herd run --limit 5 true
  2 succeeded, 0 failed, 0 skipped, 0 not checked out

A failing command is reported with its exit status and fails herd.

  $ herd run -j 1 sh -c 'echo oops >&2; exit 3'
  \xe2\x9c\x97 $ROOT/home/src/api (exit 3) (esc)
  ! oops
  
  \xe2\x9c\x97 $ROOT/home/src/web (exit 3) (esc)
  ! oops
  0 succeeded, 2 failed, 0 skipped, 0 not checked out
  [1]

never hides even a failure.

  $ herd run --show-output never false
  0 succeeded, 2 failed, 0 skipped, 0 not checked out
  [1]

  $ herd fetch
  2 succeeded, 0 failed, 0 skipped, 0 not checked out

  $ herd diff
  2 succeeded, 0 failed, 0 skipped, 0 not checked out

A change that is staged but not committed shows up in diff, as it does in
jj. A repository without changes prints nothing.

  $ echo changed >src/api/notes
  $ git -C src/api add notes
  $ herd diff -j 1 | grep -E '^(.*\$ROOT|\|.*\+changed|[0-9])'
  \xe2\x9c\x93 $ROOT/home/src/api (esc)
  | +changed
  2 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ git -C src/api rm -q -f --cached notes && rm src/api/notes

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
    branch      Print the branch.
    jj-only     Needs jj.
  $ herd branch -C src/web
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | main
  1 succeeded, 0 failed, 0 skipped, 0 not checked out

A Git checkout has no command in jj-only, so it is skipped.

  $ herd jj-only
  0 succeeded, 0 failed, 2 skipped, 0 not checked out

Arguments after -- are not herd's: the command gets them as they are, as
the shell's positional parameters, and one looking like an option is passed
on.

  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:commands
  >  {"words" {:command "printf '<%s>\\n' first \"$@\""
  >            :description "Print each word."
  >            :show-output "always"}}}
  > EOF
  $ herd words -C src/web -- --help "it's" 'a  $HOME' ''
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | <first>
  | <--help>
  | <it's>
  | <a  $HOME>
  | <>
  1 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ herd words --help | grep Usage
   Usage: herd words [option] ... [-- ARG...]

Without --, an argument is a mistake.

  $ herd words src/web 2>&1 | head -1
  usage error: could not handle option src/web

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

:shell names the shell the commands run in, as the argument vector each
command follows; its program is the command's $0. Checkout filters given
with -f run in it too.

  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:shell ["bash" "-c"]
  >  :commands
  >  {"shell" {:command "printf '%s %s\\n' \"$0\" \"$1\""
  >            :description "Print the shell."
  >            :show-output "always"}}}
  > EOF
  $ herd shell -C src/web -- arg
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | bash arg
  1 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ herd list -f '[[ $0 == bash ]]' -C src/web
  $ROOT/home/src/web\t$ROOT/origins/web (esc)
