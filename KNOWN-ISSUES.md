# Known issues

What `herd` gets wrong today, and what it leaves out. Neither half is a plan
anyone has committed to.

## Defects

Behaviour `herd` gets wrong, and knows it does. Each one is written so it
can be reproduced as it stands, and says what to do in the meantime.

### A command asking on the terminal can still hang a run

`herd` tells Git and ssh not to prompt, through `GIT_TERMINAL_PROMPT`,
`SSH_ASKPASS` and `SSH_ASKPASS_REQUIRE`, and closes standard input. Neither
reaches a program that opens the terminal itself, and an ssh older than
OpenSSH 8.4 ignores `SSH_ASKPASS_REQUIRE`. The question then waits behind
the progress display, for an answer nobody is likely to give.

```sh
$ herd run -- sh -c 'read answer </dev/tty'
```

This never finishes on a terminal, and neither does `sudo` without cached
credentials or a clone from an unknown host with such an ssh.

Ctrl-C ends the run. For an older ssh,
`GIT_SSH_COMMAND='ssh -o BatchMode=yes'` in front of the command stops it
asking.

The fix is to run each command in a session of its own, which has no
terminal to open. Janet's `os/spawn` cannot do that, so it takes native
code, and Ctrl-C would then have to be passed on to the commands by hand.

## Gaps

Things `herd` does not do, noticed while reading the code. Each says what is
absent, what it costs today, and roughly where a fix would land, so that
picking one up does not start from scratch.

### Little to read but a path and a URL

`herd list` prints the checkout state, `path` and `clone_url`, separated by
tabs. That is deliberately stable and easy to cut, but it is also everything
`herd` will tell you. It will not say which VCS a repository is checked out
with or which anchor it came from, and a script that wants either has to go
and look for itself.

The information is already in hand. A resolved repository is a dictionary,
and the entry it came from is merged into it whole, so a list whose entries
carry extra fields produces records carrying those fields:

```janet
@{:anchors @["/tmp/x"] :group "platform" :path "/tmp/x/a"
  :ssh_url "u" :tier 3 :vcs "jj"}
```

`:group` and `:tier` came from the JSON file and survived every stage, and
nothing ever looks at them. Filters exist precisely because these lists
carry more than `herd` needs, so throwing the rest away at the last step is
the odd part.

A `herd list --json` writing those records out would make the tool
scriptable and double as the way to ask why a repository was or was not
selected, which is currently guesswork. A `--null` separator for `xargs -0`
is the small version of the same idea.

### A command cannot see its entry's own fields

A command is told where it runs and where it came from, through
`HERD_REPO_*` and `HERD_AT_PATH`, but not the fields of its repository's
entry. Those such as `:group` and `:tier` are sitting in the record that
chose to run it, yet a custom command cannot branch by group or skip a tier
without reading the repository list itself.

Passing them through as well would make `:commands` in `config.jdn`
genuinely programmable. `command-environment` in `run.janet` is where they
would be added.

### No way to see what a command would do

Neither `clone` nor `run` has a `--dry-run`. For a tool whose whole purpose
is doing one thing to a few hundred directories at once, the absence is felt
most exactly when it matters most: on a configuration you have just edited,
against a tree you would rather not have to undo.

`herd list` is the better alternative, and a `--dry-run` would add little to
it. It takes the same selection options as the command, so run it with the
options you mean to give `clone` or `run`, and it shows the repositories the
command would affect:

```sh
$ herd clone -f work     # what will this create?
$ herd list --not-ok -t -f work
```

`--not-ok` keeps the repositories that are missing or blocked, which are the
ones `clone` acts on, and `-t` prints them as a tree. For `run`,
`herd list -t` with the same options shows the repositories the command
would run in.

### A run cannot be told to stop at the first failure

Every command works through the whole selection regardless of what happens.
That is the right default — one repository failing is no reason to abandon
the rest — but there is no way to ask for the other behaviour, and for a
long `clone` over a bad network it is usually what you want.

This is cheaper than it was. `parallel.janet` already carries a stop flag
and a worker loop that checks it before claiming the next repository, added
so that an interrupt could wind a run down; a `--fail-fast` would set the
same flag from a failed outcome rather than from a signal.

### The progress display cannot be turned off or on

Whether the live block is drawn is decided solely by
`(default live (os/isatty stderr))`. There is no `--quiet`, no
`--no-progress`, and no way to force it when stderr is not a terminal.
`TERM=dumb` gets the escape sequences like anything else, and `NO_COLOR`
means nothing here.

### Cloning cannot be tuned

`clone-process-command` builds one fixed argument vector per VCS. There is
no `--depth` for a shallow clone, no way to name a remote or a default
branch, and no retry when a clone fails for a reason that will not recur.
Across a few hundred repositories on an uncertain network, the last of those
is the one that bites: a single transient failure means running the whole
command again, even though `clone` will correctly skip everything it already
did.

### The BSD binaries have never run

Every Linux and macOS binary runs the command-line tests on its own platform
before a release publishes it. GitHub has no OpenBSD or FreeBSD runners, so
the four BSD binaries are cross-compiled and published without having run
anywhere. A build that does not start, or that misbehaves on the BSDs, ships
unnoticed, and `herd self-update` will install it.

OpenBSD adds a risk of its own. Its binaries link the system libc, and
OpenBSD keeps no binary compatibility across releases, so the binary built
for 7.8 can stop working on a later OpenBSD that bumps libc's major version.
Moving the target in the justfile's `dist` recipe to the newer release fixes
that, for that release.

The fix is a check job in `.github/workflows/test.yml` that boots each BSD
in a VM on an Ubuntu runner, for instance with
`cross-platform-actions/action`, and runs the binary there. `--version`
alone would catch a binary that does not start. The CLI tests would need
git, Python and prysk installed in the VM, and the jj and jp tests would
skip, since neither has BSD builds.
