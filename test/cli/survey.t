list compares the configured repositories with the ones on disk.

  $ command -v jp > /dev/null || exit 80
  $ . "$TESTDIR/setup.sh"
  $ two_repos
  $ cd "$HOME"

src/api is checked out, src/web is not, src/scratch is a repository no list
names, and notes stands where a configured repository should be.

  $ git clone -q "$ROOT/origins/api" src/api
  $ git init -q src/scratch
  $ git -C src/scratch remote add origin git@example.com:scratch.git
  $ git init -q src/bare
  $ mkdir -p src/notes
  $ echo hi >src/notes/README
  $ cat >"$CONFIG/more.json" <<'EOF'
  > [{"path": "src/notes", "ssh_url": "u"}]
  > EOF

--not-ok and --extra print what differs, its status first. The extra ones
come last, with their origin when they have one.

  $ herd list --not-ok --extra
  blocked\t$ROOT/home/src/notes\tu (esc)
  missing\t$ROOT/home/src/web\t$ROOT/origins/web (esc)
  extra\t$ROOT/home/src/bare\t (esc)
  extra\t$ROOT/home/src/scratch\tgit@example.com:scratch.git (esc)

--ok, --not-ok and --extra pick what to print.

  $ herd list --ok
  ok\t$ROOT/home/src/api\t$ROOT/origins/api (esc)

  $ herd list --not-ok
  blocked\t$ROOT/home/src/notes\tu (esc)
  missing\t$ROOT/home/src/web\t$ROOT/origins/web (esc)
  $ herd list --extra
  extra\t$ROOT/home/src/bare\t (esc)
  extra\t$ROOT/home/src/scratch\tgit@example.com:scratch.git (esc)

  $ herd list --ok --not-ok --extra
  blocked\t$ROOT/home/src/notes\tu (esc)
  ok\t$ROOT/home/src/api\t$ROOT/origins/api (esc)
  missing\t$ROOT/home/src/web\t$ROOT/origins/web (esc)
  extra\t$ROOT/home/src/bare\t (esc)
  extra\t$ROOT/home/src/scratch\tgit@example.com:scratch.git (esc)

Inside an extra repository, that repository is found, however deep.

  $ mkdir -p src/scratch/lib/deep
  $ herd list --extra -C src/scratch/lib/deep
  extra\t$ROOT/home/src/scratch\tgit@example.com:scratch.git (esc)

Discovery does not enter repositories, so a checkout nested inside one is not
reported.

  $ git init -q src/api/vendor/lib
  $ herd list --extra -C src/api

A filter narrows the configured side only. A repository it leaves out is
still configured, so it is not extra.

  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:filters {"platform" "[?group=='platform']"}}
  > EOF
  $ herd list --ok --extra -f platform
  ok\t$ROOT/home/src/api\t$ROOT/origins/api (esc)
  extra\t$ROOT/home/src/bare\t (esc)
  extra\t$ROOT/home/src/scratch\tgit@example.com:scratch.git (esc)

A checkout row's own filter does count: a repository it leaves out is not
meant to be there.

  $ git clone -q "$ROOT/origins/web" src/web
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:filters {"platform" "[?group=='platform']"}
  >  :checkouts [{:list "repos.json" :use-filters ["platform"]}]}
  > EOF
  $ herd list --extra
  extra\t$ROOT/home/src/bare\t (esc)
  extra\t$ROOT/home/src/scratch\tgit@example.com:scratch.git (esc)
  extra\t$ROOT/home/src/web\t$ROOT/origins/web (esc)
  $ rm -r "$CONFIG/config.jdn" src/web

--max-depth limits the discovery, with the path itself at depth zero.

  $ herd list --extra --max-depth 1
  $ herd list --extra --max-depth 2
  extra\t$ROOT/home/src/bare\t (esc)
  extra\t$ROOT/home/src/scratch\tgit@example.com:scratch.git (esc)
  $ herd list --extra --max-depth -1
  Invalid --max-depth: expected a non-negative integer
  [1]

Hidden directories are skipped unless --hidden asks for them.

  $ git init -q .stash/old
  $ herd list --extra --hidden
  extra\t$ROOT/home/.stash/old\t (esc)
  extra\t$ROOT/home/src/bare\t (esc)
  extra\t$ROOT/home/src/scratch\tgit@example.com:scratch.git (esc)

The discovery options mean nothing without discovery.

  $ herd list --hidden
  usage error: --hidden applies only when extra repositories are listed, by --extra
  [1]
  $ herd list --not-ok --max-depth 1
  usage error: --max-depth applies only when extra repositories are listed, by --extra
  [1]

A path that is not a directory has nothing beneath it to discover, so only
the configured side is reported there.

  $ herd list --extra -C nowhere
  $ herd list --not-ok --extra -a -C src/web
  missing\t$ROOT/home/src/web\t$ROOT/origins/web (esc)

An empty directory is missing too, since a clone could still go there.

  $ mkdir src/web
  $ herd list --not-ok --extra -C src/web
  missing\t$ROOT/home/src/web\t$ROOT/origins/web (esc)
  $ rmdir src/web

A symbolic link is not followed unless --follow-links asks for it. A link back
up does not make the walk go round forever.

  $ git init -q "$ROOT/outside/linked"
  $ ln -s "$ROOT/outside" src/link
  $ ln -s "$HOME" src/up
  $ herd list --extra
  extra\t$ROOT/home/src/bare\t (esc)
  extra\t$ROOT/home/src/scratch\tgit@example.com:scratch.git (esc)
  $ herd list --extra --follow-links
  extra\t$ROOT/home/src/bare\t (esc)
  extra\t$ROOT/home/src/link/linked\t (esc)
  extra\t$ROOT/home/src/scratch\tgit@example.com:scratch.git (esc)
  $ herd list --follow-links
  usage error: --follow-links applies only when extra repositories are listed, by --extra
  [1]

Discovery needs no configuration: with no lists, or no configuration directory,
it goes on without the message the other forms of list print.

  $ mkdir "$ROOT/empty"
  $ herd -c "$ROOT/empty" list --extra -C src/bare
  extra\t$ROOT/home/src/bare\t (esc)
  $ herd -c "$ROOT/empty" list --not-ok --extra -C src/bare
  extra\t$ROOT/home/src/bare\t (esc)
  $ (export XDG_CONFIG_HOME="$ROOT/absent"; herd list --extra -C src/bare)
  extra\t$ROOT/home/src/bare\t (esc)
  $ (export XDG_CONFIG_HOME="$ROOT/absent"; herd list --not-ok --extra -C src/bare)
  extra\t$ROOT/home/src/bare\t (esc)
