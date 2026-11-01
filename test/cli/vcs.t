Git or jj: which command a custom command runs, and how clone checks a
repository out. Stand-ins for git and jj record what they were asked.

  $ . "$TESTDIR/setup.sh"
  $ cd "$HOME"

A custom command with :command-git and :command-jj picks by what the
repository holds, and a colocated one counts as jj.

  $ mkdir -p git/.git jj/.jj both/.git both/.jj
  $ cat >"$CONFIG/repos.json" <<'EOF'
  > [{"path": "git", "ssh_url": "u"},
  >  {"path": "jj", "ssh_url": "u"},
  >  {"path": "both", "ssh_url": "u"}]
  > EOF
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:commands
  >  {"which" {:command-git "echo git" :command-jj "echo jj"
  >            :description "Say which." :show-output "always"}
  >   "git-only" {:command-git "touch selected-git"
  >               :description "Git only."}
  >   "jj-only" {:command-jj "touch selected-jj"
  >              :description "jj only."}}}
  > EOF
  $ herd which -j 1
  ✓ $ROOT/home/git
  | git
  
  ✓ $ROOT/home/jj
  | jj
  
  ✓ $ROOT/home/both
  | jj
  3 succeeded, 0 failed, 0 skipped, 0 not checked out

A repository whose VCS has no command is skipped, and the command does not
run there.

  $ herd git-only -j 1
  1 succeeded, 0 failed, 2 skipped, 0 not checked out
  $ ls */selected-git
  git/selected-git

Nor does such a repository use up --limit: git comes first and has no command
here, so the command still runs in jj.

  $ herd jj-only -j 1 -n 1
  Stopped after 1 of 3 repositories
  1 succeeded, 0 failed, 1 skipped, 0 not checked out
  $ ls */selected-jj
  jj/selected-jj

The other commands see the same VCS: a command is told it, and a jj checkout
is as good as a Git one to list and clone.

  $ herd run -j 1 --show-output always printenv HERD_REPO_VCS
  ✓ $ROOT/home/git
  | git
  
  ✓ $ROOT/home/jj
  | jj
  
  ✓ $ROOT/home/both
  | jj
  3 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ herd list --ok --status
  ok\t$ROOT/home/git\tu (esc)
  ok\t$ROOT/home/jj\tu (esc)
  ok\t$ROOT/home/both\tu (esc)
  $ herd clone
  0 cloned, 3 already checked out, 0 blocked, 0 failed

diff and fetch run the command for the repository's VCS. Stand-ins print what
they were asked.

  $ for program in git jj; do
  >   cat >"$ROOT/bin/$program" <<EOF
  > #!/bin/sh
  > echo "$program \$*"
  > EOF
  >   chmod +x "$ROOT/bin/$program"
  > done
  $ herd diff -j 1
  ✓ $ROOT/home/git
  | git diff --color=never HEAD
  
  ✓ $ROOT/home/jj
  | jj diff --color=never
  
  ✓ $ROOT/home/both
  | jj diff --color=never
  3 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ herd fetch -j 1 --show-output always
  ✓ $ROOT/home/git
  | git fetch
  
  ✓ $ROOT/home/jj
  | jj git fetch --color=never
  
  ✓ $ROOT/home/both
  | jj git fetch --color=never
  3 succeeded, 0 failed, 0 skipped, 0 not checked out

fetch hides what a success printed, and shows what a failure did. It runs with
Git's and ssh's prompts turned off, like clone.

  $ herd fetch
  3 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ cat >"$ROOT/bin/git" <<'EOF'
  > #!/bin/sh
  > echo "prompt $GIT_TERMINAL_PROMPT, askpass $SSH_ASKPASS $SSH_ASKPASS_REQUIRE"
  > echo refused >&2
  > exit 2
  > EOF
  $ herd fetch -C git
  ✗ $ROOT/home/git (exit 2)
  | prompt 0, askpass false force
  ! refused
  0 succeeded, 1 failed, 0 skipped, 0 not checked out
  [1]

clone runs git or jj with the URL and a path beside the checkout, in the
forms each expects, and moves the clone into place once it succeeds.

  $ fake git
  $ fake jj
  $ rm -r git jj both
  $ cat >"$CONFIG/repos.json" <<'EOF'
  > [{"path": "git-repo", "ssh_url": "git-url", "vcs": "git"},
  >  {"path": "jj-repo", "ssh_url": "jj-url", "vcs": "jj"}]
  > EOF
  $ rm "$CONFIG/config.jdn"
  $ herd clone -j 1 > /dev/null
  $ sed "s|$ROOT|\$ROOT|" "$ROOT/git.args"
  clone
  --
  git-url
  $ROOT/home/.herd-clone-git-repo
  $ sed "s|$ROOT|\$ROOT|" "$ROOT/jj.args"
  git
  clone
  --colocate
  --
  jj-url
  $ROOT/home/.herd-clone-jj-repo
  $ ls -A
  .config
  git-repo
  jj-repo

The VCS is settled by the entry, then the :checkouts row, then :checkout-defaults,
and a checkout none of them settles uses git.

  $ cat >"$CONFIG/repos.json" <<'EOF'
  > [{"path": "plain", "ssh_url": "u"},
  >  {"path": "own", "ssh_url": "u", "vcs": "jj"}]
  > EOF
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:checkout-defaults {:vcs "jj"}
  >  :checkouts [{:list "repos.json" :anchor "a" :vcs "git"}
  >              {:list "repos.json" :anchor "b"}]}
  > EOF
  $ for repo in a/plain a/own b/plain b/own; do
  >   rm -f "$ROOT/git.args" "$ROOT/jj.args"
  >   herd clone -C $repo > /dev/null
  >   echo "$repo: $(ls "$ROOT" | sed -n 's/\.args$//p')"
  > done
  a/plain: git
  a/own: jj
  b/plain: jj
  b/own: jj

  $ rm "$CONFIG/config.jdn"
  $ rm -f "$ROOT/git.args" "$ROOT/jj.args"
  $ herd clone -C plain > /dev/null
  $ ls "$ROOT" | sed -n 's/\.args$//p'
  git
