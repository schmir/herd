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

--status prints what differs, its status first. The extra ones come
last, with their origin when they have one.

  $ herd list --status
  blocked\t$ROOT/home/src/notes\tu (esc)
  missing\t$ROOT/home/src/web\t$ROOT/origins/web (esc)
  extra\t$ROOT/home/src/bare\t (esc)
  extra\t$ROOT/home/src/scratch\tgit@example.com:scratch.git (esc)

--ok, --missing and --extra pick what to print, in the plain format
unless --status asks for the status.

  $ herd list --ok
  $ROOT/home/src/api\t$ROOT/origins/api (esc)

  $ herd list --missing
  $ROOT/home/src/notes\tu (esc)
  $ROOT/home/src/web\t$ROOT/origins/web (esc)
  $ herd list --extra
  $ROOT/home/src/bare\t (esc)
  $ROOT/home/src/scratch\tgit@example.com:scratch.git (esc)

  $ herd list --ok --missing --extra --status
  blocked\t$ROOT/home/src/notes\tu (esc)
  ok\t$ROOT/home/src/api\t$ROOT/origins/api (esc)
  missing\t$ROOT/home/src/web\t$ROOT/origins/web (esc)
  extra\t$ROOT/home/src/bare\t (esc)
  extra\t$ROOT/home/src/scratch\tgit@example.com:scratch.git (esc)

Inside an extra repository, that repository is found, however deep.

  $ mkdir -p src/scratch/lib/deep
  $ herd list --extra -C src/scratch/lib/deep
  $ROOT/home/src/scratch\tgit@example.com:scratch.git (esc)

The scan does not enter repositories, so a checkout nested inside one is not
reported.

  $ git init -q src/api/vendor/lib
  $ herd list --extra -C src/api

A filter narrows the configured side only. A repository it leaves out is
still configured, so it is not extra.

  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:filters {"platform" "[?group=='platform']"}}
  > EOF
  $ herd list --status --ok --extra -f platform
  ok\t$ROOT/home/src/api\t$ROOT/origins/api (esc)
  extra\t$ROOT/home/src/bare\t (esc)
  extra\t$ROOT/home/src/scratch\tgit@example.com:scratch.git (esc)

A checkout row's own filter does count: a repository it leaves out is not
meant to be there.

  $ git clone -q "$ROOT/origins/web" src/web
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:filters {"platform" "[?group=='platform']"}
  >  :checkouts [{:from "repos.json" :filter ["platform"]}]}
  > EOF
  $ herd list --extra
  $ROOT/home/src/bare\t (esc)
  $ROOT/home/src/scratch\tgit@example.com:scratch.git (esc)
  $ROOT/home/src/web\t$ROOT/origins/web (esc)
  $ rm -r "$CONFIG/config.jdn" src/web

--max-depth limits the scan, with the path itself at depth zero.

  $ herd list --extra --max-depth 1
  $ herd list --extra --max-depth 2
  $ROOT/home/src/bare\t (esc)
  $ROOT/home/src/scratch\tgit@example.com:scratch.git (esc)
  $ herd list --extra --max-depth -1
  Invalid --max-depth: expected a non-negative integer
  [1]

Hidden directories are skipped unless --hidden asks for them.

  $ git init -q .stash/old
  $ herd list --extra --hidden
  $ROOT/home/.stash/old\t (esc)
  $ROOT/home/src/bare\t (esc)
  $ROOT/home/src/scratch\tgit@example.com:scratch.git (esc)

The scan options mean nothing without a scan.

  $ herd list --hidden
  usage error: --hidden applies only when extra repositories are listed, by --extra or a plain --status
  [1]
  $ herd list --missing --status --max-depth 1
  usage error: --max-depth applies only when extra repositories are listed, by --extra or a plain --status
  [1]

A path that is not a directory has nothing beneath it to scan, so only
the configured side is reported there.

  $ herd list --extra -C nowhere
  $ herd list --status -a -C src/web
  missing\t$ROOT/home/src/web\t$ROOT/origins/web (esc)
