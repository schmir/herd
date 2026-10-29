HERD_CONFIG names the configuration to read in place of the one in
XDG_CONFIG_HOME. It is exported and unset explicitly, since sh keeps an
assignment in front of a function, as herd is here, after the call.

  $ . "$TESTDIR/setup.sh"
  $ two_repos

A directory is read as the configuration directory.

  $ mkdir work
  $ echo '[{"path": "src/tool", "ssh_url": "tool-url"}]' >work/repos.json
  $ export HERD_CONFIG="$ROOT/work"
  $ herd list --all-anchors
  $ROOT/home/src/tool\ttool-url (esc)

A file is read in place of config.jdn, with the lists beside it.

  $ echo '{:checkouts [{:list "repos.json" :anchor "elsewhere"}]}' \
  >   >work/work.jdn
  $ export HERD_CONFIG="$ROOT/work/work.jdn"
  $ herd list --all-anchors
  $ROOT/home/elsewhere/src/tool\ttool-url (esc)

A relative one resolves from the working directory, and messages about the
file name it.

  $ echo '{:checkouts [{:list "gone.json"}]}' >work/work.jdn
  $ export HERD_CONFIG=work/work.jdn
  $ herd list
  Configuration error: work.jdn: :checkouts reads "gone.json", which is not in the configuration directory
  [1]

An empty one is no HERD_CONFIG at all.

  $ export HERD_CONFIG=
  $ herd list --all-anchors
  $ROOT/home/src/api\t$ROOT/origins/api (esc)
  $ROOT/home/src/web\t$ROOT/origins/web (esc)

One that names nothing is an error, even for --help.

  $ export HERD_CONFIG="$ROOT/missing"
  $ herd --help
  Configuration error: HERD_CONFIG names $ROOT/missing, which does not exist
  [1]

-c or --config names the configuration on the command line, in place of
HERD_CONFIG, and takes what HERD_CONFIG takes.

  $ echo '{}' >work/work.jdn
  $ herd -c work/work.jdn list --all-anchors
  $ROOT/home/src/tool\ttool-url (esc)
  $ herd --config="$ROOT/work" list --all-anchors
  $ROOT/home/src/tool\ttool-url (esc)
  $ unset HERD_CONFIG

One that names nothing is an error that says where the name came from.

  $ herd -c "$ROOT/missing" list
  Configuration error: --config names $ROOT/missing, which does not exist
  [1]

It belongs to bare herd, before the command.

  $ herd list -c work | head -n 1
  usage error: unknown flag -c
  $ herd --help | grep -e --config
   -c, --config PATH                           Read the configuration from PATH, a directory or a settings file, in place of HERD_CONFIG.

A herd started by a command reads the same configuration, wherever it runs.

  $ herd clone -a >/dev/null
  $ herd -c "$CONFIG" run -j 1 -a --show-output always printenv HERD_CONFIG
  \xe2\x9c\x93 $ROOT/home/src/api (esc)
  | $ROOT/home/.config/herd
  
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | $ROOT/home/.config/herd
  2 succeeded, 0 failed, 0 skipped, 0 not checked out

So does one started without -c: a relative HERD_CONFIG is handed on as an
absolute path, and the default directory is named too.

  $ (export HERD_CONFIG=home/.config/herd && herd run -C home/src/web --show-output always printenv HERD_CONFIG)
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | $ROOT/home/.config/herd
  1 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ herd run -C home/src/web --show-output always printenv HERD_CONFIG
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | $ROOT/home/.config/herd
  1 succeeded, 0 failed, 0 skipped, 0 not checked out
