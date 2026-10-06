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
  >               :description "Git only."}}}
  > EOF
  $ herd which -j 1
  ✓ $ROOT/home/git
  | stdout
  |   git
  
  ✓ $ROOT/home/jj
  | stdout
  |   jj
  
  ✓ $ROOT/home/both
  | stdout
  |   jj
  3 succeeded, 0 failed, 0 skipped, 0 not checked out

A repository whose VCS has no command is skipped, and the command does not
run there.

  $ herd git-only -j 1
  1 succeeded, 0 failed, 2 skipped, 0 not checked out
  $ ls */selected-git
  git/selected-git

clone runs git or jj with the URL and the path, in the forms each expects.

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
  $ROOT/home/git-repo
  $ sed "s|$ROOT|\$ROOT|" "$ROOT/jj.args"
  git
  clone
  --colocate
  --
  jj-url
  $ROOT/home/jj-repo

The VCS is settled by the entry, then the :checkouts row, then :defaults,
and a checkout none of them settles uses jj.

  $ cat >"$CONFIG/repos.json" <<'EOF'
  > [{"path": "plain", "ssh_url": "u"},
  >  {"path": "own", "ssh_url": "u", "vcs": "jj"}]
  > EOF
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:defaults {:vcs "jj"}
  >  :checkouts [{:from "repos.json" :anchor "a" :vcs "git"}
  >              {:from "repos.json" :anchor "b"}]}
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
  jj
