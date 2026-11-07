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

--pager is taken, but off a terminal it changes nothing.

  $ herd run -p true
  2 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ herd run --pager true
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

A custom command selects as run does: -a looks past the anchors, and -f
narrows.

  $ herd words -C /
  No configuration anchor contains /; use -a/--all-anchors to consider every anchor
  0 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ herd words -j 1 -a -C /
  \xe2\x9c\x93 $ROOT/home/src/api (esc)
  | <first>
  
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | <first>
  2 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ herd words -f 'test "$HERD_REPO_PATH" = src/web'
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | <first>
  1 succeeded, 0 failed, 0 skipped, 0 not checked out

A custom command that does not say keeps quiet on success, and shows a
failure's output. Any failure among successes fails herd.

  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:commands
  >  {"api-only" {:command "echo \"$HERD_REPO_PATH\"; test \"$HERD_REPO_PATH\" = src/api"
  >               :description "Succeed in src/api."}}}
  > EOF
  $ herd api-only -j 1
  \xe2\x9c\x97 $ROOT/home/src/web (exit 1) (esc)
  | src/web
  1 succeeded, 1 failed, 0 skipped, 0 not checked out
  [1]

A definition of diff or fetch replaces the one herd supplies.

  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:commands
  >  {"diff" {:command "echo my diff" :description "My diff." :show-output "always"}
  >   "fetch" {:command "echo my fetch" :description "My fetch." :show-output "always"}}}
  > EOF
  $ herd --help | grep -E '^  (diff|fetch) '
    diff        My diff.
    fetch       My fetch.
  $ herd diff -C src/web
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | my diff
  1 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ herd fetch -C src/web
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | my fetch
  1 succeeded, 0 failed, 0 skipped, 0 not checked out

A command finds the repository it runs in, and whether herd colors its
output, in its environment.

  $ herd run -C src/web --show-output always sh -c \
  >   'printf "%s\n" "$HERD_REPO_ANCHOR" "$HERD_REPO_PATH" "$HERD_REPO_URL" "$HERD_REPO_VCS" "$HERD_COLOR"'
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | $ROOT/home
  | src/web
  | $ROOT/origins/web
  | git
  | never
  1 succeeded, 0 failed, 0 skipped, 0 not checked out

Its path is also given relative to where it was selected from: -C, or the
working directory, even for a repository that contains it.

  $ herd run -j 1 --show-output always sh -c 'printf "%s %s\n" "$HERD_AT_PATH" "$HERD_REPO_RELPATH"'
  \xe2\x9c\x93 $ROOT/home/src/api (esc)
  | $ROOT/home src/api
  
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | $ROOT/home src/web
  2 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ mkdir -p src/web/lib
  $ herd run -C src/web/lib --show-output always printenv HERD_REPO_RELPATH
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | ..
  1 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ herd run -C src/web --show-output always printenv HERD_REPO_RELPATH
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | .
  1 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ rmdir src/web/lib

A command finds its standard input closed, so it reads nothing of herd's.

  $ echo from-herd | herd run -C src/web --show-output always sh -c 'cat; echo "read $?"'
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | read 0
  1 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ echo from-herd | herd list -C src/web -f 'test -z "$(cat)"'
  ok\t$ROOT/home/src/web\t$ROOT/origins/web (esc)

It finds Git's and ssh's prompts turned off, unless the environment already
says otherwise.

  $ herd run -C src/web --show-output always sh -c 'echo "$GIT_TERMINAL_PROMPT $SSH_ASKPASS $SSH_ASKPASS_REQUIRE"'
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | 0 false force
  1 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ (export GIT_TERMINAL_PROMPT=1 SSH_ASKPASS=mine SSH_ASKPASS_REQUIRE=prefer
  >  herd run -C src/web --show-output always sh -c 'echo "$GIT_TERMINAL_PROMPT $SSH_ASKPASS $SSH_ASKPASS_REQUIRE"')
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | 1 mine prefer
  1 succeeded, 0 failed, 0 skipped, 0 not checked out

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
  ok\t$ROOT/home/src/web\t$ROOT/origins/web (esc)
