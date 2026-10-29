HERD_CONFIG names the configuration to read in place of the one in
XDG_CONFIG_HOME.

  $ . "$TESTDIR/setup.sh"
  $ two_repos

A directory is read as the configuration directory.

  $ mkdir work
  $ echo '[{"path": "src/tool", "ssh_url": "tool-url"}]' >work/repos.json
  $ HERD_CONFIG="$ROOT/work" herd list --all-anchors
  $ROOT/home/src/tool\ttool-url (esc)

A file is read in place of config.jdn, with the lists beside it.

  $ echo '{:checkouts [{:list "repos.json" :anchor "elsewhere"}]}' \
  >   >work/work.jdn
  $ HERD_CONFIG="$ROOT/work/work.jdn" herd list --all-anchors
  $ROOT/home/elsewhere/src/tool\ttool-url (esc)

A relative one resolves from the working directory, and messages about the
file name it.

  $ echo '{:checkouts [{:list "gone.json"}]}' >work/work.jdn
  $ HERD_CONFIG=work/work.jdn herd list
  Configuration error: work.jdn: :checkouts reads "gone.json", which is not in the configuration directory
  [1]

An empty one is no HERD_CONFIG at all.

  $ HERD_CONFIG= herd list --all-anchors
  $ROOT/home/src/api\t$ROOT/origins/api (esc)
  $ROOT/home/src/web\t$ROOT/origins/web (esc)

One that names nothing is an error, even for --help.

  $ HERD_CONFIG="$ROOT/missing" herd --help
  Configuration error: HERD_CONFIG names $ROOT/missing, which does not exist
  [1]
