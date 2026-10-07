# Known issues

What `herd` gets wrong today, and what it leaves out. Neither half is a plan
anyone has committed to.

## Defects

Behaviour `herd` gets wrong, and knows it does. Each one is written so it
can be reproduced as it stands, and says what to do in the meantime.

### An anchor beginning with `~` is taken literally

A relative `:anchor` resolves from `$HOME` already, so writing `~/` in front
of one is redundant. It is not an error, though, and it is not expanded
either: the `~` becomes a directory of that name.

```janet
{:checkouts [{:from "repos.json" :anchor "~/src"}]}
```

```sh
$ herd list
/home/you/~/src/acme/api	git@github.com:acme/api.git
```

`herd clone` will create that directory rather than refuse it, leaving a
checkout somewhere nobody meant. A `$HOME/src` written instead of `~/src`
goes the same way, for the same reason: what a shell expands before a
program sees it, a configuration file does not.

Write a relative anchor with no prefix at all — `src`, not `~/src` — and it
resolves under `$HOME` as intended. An anchor that should not resolve from
`$HOME` is written absolute, and is used exactly as written.

The fix is to reject a leading `~` or `$` where the anchor is validated,
since neither can be meant literally by anyone.

## Gaps

Things `herd` does not do, noticed while reading the code. Each says what is
absent, what it costs today, and roughly where a fix would land, so that
picking one up does not start from scratch.

### No way to point herd at a different configuration

`config-directory` in `config.janet` reads `XDG_CONFIG_HOME`, falls back to
`HOME`, and that is the whole of it. There is no `--config-dir` and no
`HERD_CONFIG`.

This is the largest gap, because it is the one that makes other things
awkward rather than merely absent. Trying a configuration out means moving
the real one aside. Keeping a work set and a personal set apart means
setting `XDG_CONFIG_HOME` for every invocation, which also moves every other
program's configuration. Running `herd` from a script or a CI job means
arranging a fake `HOME`, which is what the test suite already does in half a
dozen places.

A `--config-dir PATH` option alongside `--at` and `--all-anchors`, read
before `config-directory` is consulted, would cover all three. An
environment variable is the cheaper half of it and covers the scripting case
alone.

### Little to read but a path and a URL

`herd list` prints `path`, a tab, and `ssh_url`, and `--status` puts the
checkout state in front. That is deliberately stable and easy to cut, but it
is also everything `herd` will tell you. It will not say which VCS a
repository is checked out with or which anchor it came from, and a script
that wants either has to go and look for itself.

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

### A command cannot tell which repository it is in

`run-in-repository` sets the working directory and hands the command
`{:in devnull}`. Everything else the command knows it has to work out
itself, which in practice means `pwd`. The URL, the VCS, and the entry's own
fields are all sitting in the record that chose to run it.

Exporting `HERD_REPO_PATH`, `HERD_REPO_URL` and `HERD_REPO_VCS` would let a
custom command act on what it is looking at — push to the right remote,
branch by group, skip a tier. Passing the entry's extra fields through as
well would make `:commands` in `config.jdn` genuinely programmable.

Note that the environment is inherited by omission: `os/spawn` passes the
parent's environment through unless it is given the `:e` flag, so adding
variables means copying `os/environ` and passing that flag, not just
extending the dictionary that is there now.

### No way to see what a command would do

Neither `clone` nor `run` has a `--dry-run`. For a tool whose whole purpose
is doing one thing to a few hundred directories at once, the absence is felt
most exactly when it matters most: on a configuration you have just edited,
against a tree you would rather not have to undo.

`clone` is the one that wants it first, since it creates directories. It
already knows everything needed to say what it would do before doing any of
it — `clone-repositories` has the full list and the decision for each.

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
`TERM=dumb` gets the escape sequences like anything else, and `NO_COLOR` —
which the justfile honours — means nothing here.

### Cloning cannot be tuned

`clone-process-command` builds one fixed argument vector per VCS. There is
no `--depth` for a shallow clone, no way to name a remote or a default
branch, and no retry when a clone fails for a reason that will not recur.
Across a few hundred repositories on an uncertain network, the last of those
is the one that bites: a single transient failure means running the whole
command again, even though `clone` will correctly skip everything it already
did.
