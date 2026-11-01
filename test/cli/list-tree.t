list --tree draws the selected repositories as a tree instead of lines.

  $ . "$TESTDIR/setup.sh"
  $ two_repos
  $ cd "$HOME"
  $ herd list --tree
  $ROOT/home/src (2 repositories)
  ├── api
  └── web

-t is short for --tree.

  $ herd list -t -C src/api
  $ROOT/home/src/api

The selection decides what is drawn, as it does for the lines.

  $ herd list --tree -C src/web
  $ROOT/home/src/web

--status marks each repository with its status, as the lines begin with it;
on its own it draws only what differs,
and --ok and --missing pick which are drawn.

  $ mkdir -p src/api/.git
  $ herd list --tree --status --ok --missing
  $ROOT/home/src (2 repositories)
  ├── api (ok)
  └── web (missing)
  $ herd list --tree --status
  $ROOT/home/src/web (missing)
  $ herd list --tree --missing
  $ROOT/home/src/web

Nothing selected draws nothing.

  $ herd list --tree --missing -C src/api
  $ herd list --tree --ok -C src/web

--no-pager prints the tree directly. The pager only runs on a terminal, which
a test does not have, so this shows that the option is taken. There is no pager
to turn off without --tree.

  $ herd list --tree -P -C src/web
  $ROOT/home/src/web
  $ herd list --tree --no-pager -C src/web
  $ROOT/home/src/web
  $ herd list --no-pager
  usage error: --no-pager applies only with --tree
  [1]

The tree draws extra repositories like the others, and the discovery options
apply to it as they do to the lines.

  $ git init -q src/scratch
  $ herd list --tree --extra
  $ROOT/home/src/scratch
  $ herd list --tree --status
  $ROOT/home/src (2 repositories)
  ├── scratch (extra)
  └── web (missing)
  $ herd list --tree --extra --max-depth 1
  $ herd list --tree --hidden
  usage error: --hidden applies only when extra repositories are listed, by --extra or a plain --status
  [1]
