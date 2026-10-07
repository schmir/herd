The command line itself: help, version, and the mistakes herd rejects.

  $ . "$TESTDIR/setup.sh"

--version answers without reading the configuration, so a broken one does
not stop it.

  $ echo '[' >"$CONFIG/broken.json"
  $ herd --version
  herd \S+ (re)
  $ rm "$CONFIG/broken.json"

--help shows how herd was invoked and lists the built-in commands.

  $ herd --help | head -1
  usage: herd \[option\] \.\.\. ? (re)
  $ herd --help | sed -n '/Commands:/,/^ *$/p'
   Commands:
    clone       Check out the configured repositories beneath a path.
    completions Print a shell completion script for herd.
    fetch       Fetch Git remotes in configured repositories beneath a path.
    list        Print the configured repositories beneath a path.
    run         Run a command in each configured repository beneath a path.
  \s* (re)

Naming no command shows the same help, but fails.

  $ herd > /dev/null
  [1]

  $ herd bogus
  Unknown command "bogus"
  [1]

Flags take no value.

  $ herd --version=1
  usage error: --version is a flag and takes no value
  [1]
  $ herd list --all-anchors=yes
  usage error: --all-anchors is a flag and takes no value
  [1]

An option another command has is unknown to list.

  $ herd list --jobs 2 | head -1
  usage error: unknown option jobs

--jobs takes a positive integer.

  $ herd clone -j 0
  Invalid --jobs: expected a positive integer no greater than 2147483647
  [1]
  $ herd fetch --jobs many
  Invalid --jobs: expected a positive integer no greater than 2147483647
  [1]

--show-output takes one of three conditions.

  $ herd run --show-output sometimes true
  Invalid --show-output: expected "never", "on-failure", or "always"
  [1]

  $ herd run
  herd run needs a command
  [1]

Nothing configured yet is not a failure.

  $ herd list
  No configuration files in $ROOT/home/.config/herd

Without XDG_CONFIG_HOME and HOME there is nowhere to look.

  $ env -u HOME -u XDG_CONFIG_HOME "$HERD" list
  Neither XDG_CONFIG_HOME nor HOME is set, so there is no configuration directory to read
  [1]

-V is the short form of --version.

  $ test "$(herd -V)" = "$(herd --version)"

Every command selects by location, anchor and filter, and those that work
on repositories document their defaults.

  $ for command in clone fetch list run; do
  >   herd $command --help | grep -E -e '-(C|a|f|j), |--show-output' | sed 's/  */ /g'
  > done
   -a, --all-anchors Consider repositories from every configuration anchor.
   -C, --at PATH=$ROOT Select repositories using PATH as the working location.
   -f, --filter NAME Select only repositories kept by the named filter.
   -j, --jobs N=6 Run at most N repository operations at the same time.
   -a, --all-anchors Consider repositories from every configuration anchor.
   -C, --at PATH=$ROOT Select repositories using PATH as the working location.
   -f, --filter NAME Select only repositories kept by the named filter.
   -j, --jobs N=6 Run at most N repository operations at the same time.
   --show-output WHEN=on-failure Show command output: never, on-failure, or always.
   -a, --all-anchors Consider repositories from every configuration anchor.
   -C, --at PATH=$ROOT Select repositories using PATH as the working location.
   -f, --filter NAME Select only repositories kept by the named filter.
   -a, --all-anchors Consider repositories from every configuration anchor.
   -C, --at PATH=$ROOT Select repositories using PATH as the working location.
   -f, --filter NAME Select only repositories kept by the named filter.
   -j, --jobs N=6 Run at most N repository operations at the same time.
   --show-output WHEN=on-failure Show command output: never, on-failure, or always.

Asking for help in a cluster works only when every flag in it is known;
anything else in it, before or after the h, is a mistake.

  $ for args in "list -h" "list -ah" "list -ha" "-h"; do
  >   herd $args > /dev/null && echo "$args: help"
  > done
  list -h: help
  list -ah: help
  list -ha: help
  -h: help
  $ for args in "list -hx" "list -xh" "fetch -jh" "list -h --bogus" \
  >             "-x list -h" "--version=" "--help=x" "list -C / --help=x"; do
  >   herd $args | grep -q 'usage error' && echo "$args: usage error"
  > done
  list -hx: usage error
  list -xh: usage error
  fetch -jh: usage error
  list -h --bogus: usage error
  -x list -h: usage error
  --version=: usage error
  --help=x: usage error
  list -C / --help=x: usage error

A flag is only looked for where options are read: the value of an option
and the command run passes on are left alone.

  $ herd list --at --all-anchors=no
  No configuration files in $ROOT/home/.config/herd
  $ herd run true --help=x | tail -1
  No configuration files in $ROOT/home/.config/herd
  $ herd run -j 1 -- true --version=x | tail -1
  No configuration files in $ROOT/home/.config/herd

Every --jobs that is not a positive integer in range is refused.

  $ for jobs in -2 1.5 2147483648 1e18; do herd run --jobs $jobs true; done
  Invalid --jobs: expected a positive integer no greater than 2147483647
  Invalid --jobs: expected a positive integer no greater than 2147483647
  Invalid --jobs: expected a positive integer no greater than 2147483647
  Invalid --jobs: expected a positive integer no greater than 2147483647
  [1]

Naming a configuration file on the command line is not how herd is told
about one.

  $ echo '[]' > extra.json
  $ herd list --at . extra.json | head -1
  usage error: could not handle option extra.json

A custom command is listed in --help with its description, and its own
help shows its configured output default. A configured :jobs becomes the
documented default, whatever the command line asks for.

  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:jobs 2
  >  :commands {"mark" {:command "touch marker"
  >                     :description "Create a marker in each repository."
  >                     :show-output "always"}}}
  > EOF
  $ herd --help | grep '^  mark'
    mark        Create a marker in each repository.
  $ herd mark --help | grep -E -e '-j, |--show-output' | sed 's/  */ /g'
   -j, --jobs N=2 Run at most N repository operations at the same time.
   --show-output WHEN=always Show command output: never, on-failure, or always.
  $ for command in clone fetch run; do herd $command --help | grep -o 'jobs N=[0-9]*'; done
  jobs N=2
  jobs N=2
  jobs N=2
  $ herd run --jobs 5 --help | grep -o 'jobs N=[0-9]*'
  jobs N=2

The bare invocation prints exactly what --help prints.

  $ herd --help > help.txt
  $ herd > bare.txt
  [1]
  $ cmp help.txt bare.txt

-V works with a broken configuration, like --version.

  $ echo '{:checkouts' >"$CONFIG/config.jdn"
  $ herd list > /dev/null
  [1]
  $ herd -V
  herd \S+ (re)
