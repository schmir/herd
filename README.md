# herd

`herd` manages a collection of Git repositories, checked out with
[Jujutsu](https://jj-vcs.github.io/jj/latest/) or with Git. It can clone
missing working copies, fetch remotes, and run a command in the selected
repositories, with a configurable number of operations running in parallel
(six by default).

## Install

Prebuilt binaries are available for Linux (x86-64 and ARM64) and macOS
(ARM64) on the
[releases page](https://github.com/schmir/herd/releases/latest). Every
release ships one `herd-<version>-<platform>.tar.gz` per platform, each
holding a single executable named `herd`, so unpacking it leaves the binary
ready to move onto your `PATH`:

```sh
tar xzf herd-v1.2.3-macos-arm64.tar.gz
install -m 755 herd ~/.local/bin/herd
```

On macOS, a browser marks whatever it downloads as quarantined, and `herd`
is not signed with an Apple Developer ID, so Gatekeeper refuses to run a
quarantined copy. Unpacking the archive with `tar` in a terminal leaves the
binary unmarked, but Safari and Finder unpack archives themselves and do
pass the mark on. If macOS declines to run `herd`, clear it:

```sh
xattr -d com.apple.quarantine ~/.local/bin/herd
```

`herd --version` reports which release a binary is. Cloning and fetching
also require the VCS you use, `jj` or `git`, on `PATH`.

To build from source with Nix:

```sh
nix develop
just build
install -m 755 build/herd ~/.local/bin/herd
```

Without Nix, install [Janet](https://janet-lang.org/),
[JPM](https://github.com/janet-lang/jpm), `just`, and `jj`, then run
`just build`.

## Configure

`herd` reads its configuration from `$XDG_CONFIG_HOME/herd`, or from
`~/.config/herd` when `XDG_CONFIG_HOME` is not set.

### Repositories

Every `*.json` file in the configuration directory holds an array of
repositories:

```json
[
  {
    "path": "src/acme/api",
    "ssh_url": "git@github.com:acme/api.git"
  },
  {
    "path": "src/acme/web",
    "ssh_url": "git@github.com:acme/web.git",
    "vcs": "git"
  }
]
```

Both `path` and `ssh_url` are required and must be strings. The optional
`vcs` is `"jj"` or `"git"` and decides how `herd clone` checks that
repository out; see [Checkout options](#checkout-options).

Every configuration file is checked out under one or more **anchors**: the
directories its relative paths resolve against. By default there is a single
anchor, `$HOME`, or the configuration directory if `HOME` is not set.
Absolute paths remain unchanged, whatever the anchors. The anchors also
decide which repositories a command considers; see [Selection](#selection).

You can split repositories across any number of JSON files; files are loaded
in name order. Duplicate paths are accepted only when their URLs and their
checkout options agree.

A repository list holds nothing but repositories, so whatever writes one
needs to know nothing else. Where a list is anchored and how its
repositories are checked out is configured by the `:checkouts` rows in
`config.jdn`.

### Settings

An optional `config.jdn` in the configuration directory carries the
settings:

```janet
{:jobs 6

 :defaults {:anchor "src" :vcs "jj"}

 :checkouts
 [{:from "work.json"   :anchor "work"}
  {:from "work.json"   :anchor "/srv/review" :vcs "git"}
  {:from "vendor.json" :anchor "/opt/vendor" :vcs "git"}]

 :commands
 {"update" {:command "jj git fetch && jj up"
            :description "Fetch and update each repository."}}}
```

`:jobs` is the default number of operations run in parallel.

`:checkouts` is where the repository lists are anchored. Each row reads one
configuration file, named by `:from` as it is named in the configuration
directory, and anchors its repositories at one directory. `:defaults` holds
what every row starts from, so a row naming one setting keeps the rest, and
a list no row reads is checked out once from the defaults alone — dropping a
list into the configuration directory checks it out rather than waiting to
be mentioned.

A row whose `:from` is not in the configuration directory is an error rather
than a row quietly ignored: a row left behind by a renamed or deleted list
would otherwise stop applying without a word, and the list it was written
for would fall back to the defaults.

### Anchors

A row's `:anchor` is the directory the relative paths in its configuration
file resolve against. A relative anchor resolves from `$HOME`, so the first
row above anchors `work.json` at `$HOME/work` and an entry such as
`team/api` resolves to `$HOME/work/team/api`. An absolute anchor is used
exactly as written and need not exist yet. A row that names no anchor at all
falls back to `:defaults`, and without those to `$HOME` — or to the
configuration file's own directory, when the file is not in the
configuration directory.

Several rows reading the same file describe the same set of repositories
checked out under each of their anchors. `team/api` above names both
`$HOME/work/team/api` and `/srv/review/team/api`, and `herd clone` checks
the repository out at each. An entry with an absolute path resolves the same
way under every anchor, so it stays a single repository, reachable from all
of them.

A configuration file may itself be a symlink. It is still anchored by its
visible location in the configuration directory, which is also the name
`:from` knows it by, so point its rows at the directory tree it describes
when the list lives next to that tree.

### Checkout options

`:vcs` decides how `herd clone` checks a repository out: `"jj"` for a
colocated Git/Jujutsu working copy, `"git"` for a plain Git one. It can be
set at three levels, and the innermost one that names it wins:

| Level          | Where it is written                |
| -------------- | ---------------------------------- |
| the repository | `"vcs"` on an entry in a JSON list |
| the checkout   | `:vcs` on a `:checkouts` row       |
| every checkout | `:vcs` in `:defaults`              |

A repository no level settles is checked out with `jj`.

The row is where a location, rather than a repository, decides. With the
settings above, one `team/api` entry in `work.json` becomes a jj working
copy at `$HOME/work/team/api` and a plain Git one at `/srv/review/team/api`,
while an entry naming `"vcs": "git"` itself is a Git checkout under either
anchor.

### Custom commands

Each entry in `:commands` becomes a subcommand with the same options as
`herd run`, listed in `herd --help` by its `:description`:

```janet
{:commands
 {"update" {:command "jj git fetch && jj up"
            :description "Fetch and update each repository."}
  "status" {:command-git "git status --short"
            :command-jj "jj st"
            :description "Show the working-copy status."
            :show-output "always"}}}
```

A command is either a single `:command` string, or `:command-git` and
`:command-jj` strings chosen by what the repository actually contains — a
`.jj` directory selects the jj command, a `.git` directory the Git one. A
repository whose VCS has no command is skipped. Commands run through
`sh -c`, so pipes and `&&` work. `:show-output` sets that command's default
output condition; see [Use](#use). Custom names cannot shadow the built-in
commands.

## Use

List the selected repositories, one per line, as a path and URL separated by
a tab:

```sh
herd list
```

Every configured repository is listed whether or not it is checked out, so
the output is a stable input for scripts:

```
/home/you/src/acme/api	git@github.com:acme/api.git
/home/you/src/acme/web	git@github.com:acme/web.git
```

Clone missing repositories, as colocated Git/Jujutsu working copies or as
plain Git ones, following the checkout options in force for each:

```sh
herd clone
```

An existing non-empty target directory is treated as already checked out and
is left unchanged. `clone` finishes with a summary and exits non-zero if any
clone failed:

```
2 cloned, 1 already checked out, 0 failed
```

Fetch the Git remotes of every checked-out repository:

```sh
herd fetch
```

Run any command in every checked-out repository:

```sh
herd run jj st
herd run --show-output always git remote -v
```

The command runs with the repository as its working directory.
`--show-output` takes `never`, `on-failure`, or `always`, and defaults to
`on-failure`: a successful command stays quiet, a failing one shows what it
printed. Output is captured per repository and reported as one block, so
parallel runs stay readable:

```
✓ /home/you/src/acme/api
| stdout
|   origin	git@github.com:acme/api.git (fetch)
|   origin	git@github.com:acme/api.git (push)
```

A failed command is headed by `✗` and its exit status.

Commands do not receive terminal input, so they must be non-interactive.
`run`, `fetch`, and custom commands finish with a summary and exit non-zero
if any command failed:

```
3 succeeded, 0 failed, 0 skipped, 1 not checked out
```

Repositories that are not checked out are skipped rather than counted as
failures, so `herd run` is safe to use before everything has been cloned.

`clone`, `fetch`, `run`, and custom commands take `-j N` (or `--jobs N`) to
override how many repositories are worked on at the same time:

```sh
herd clone -j 12
```

## Selection

Commands act on the repositories selected from the current directory.
Selection has two parts, and both must hold.

By path, a repository is selected when it is at or below the current
directory, or when it contains the current directory. Standing anywhere
inside a working copy therefore selects that repository, however deep.

By anchor, only repositories reached from an anchor that contains the
current directory take part. This keeps a command run from a broad parent
such as `/` from reaching unrelated groups of repositories. Given:

```
~/.config/herd/personal.json          anchored at ~
~/.config/herd/work.json              anchored at ~/work
~/.config/herd/config.jdn             {:checkouts [{:from "work.json" :anchor "work"}]}
```

running `herd list` in `~` selects only the repositories from
`personal.json`, because `~/work` does not contain `~`. Running it in
`~/work/team/api` selects from both files, because `~` and `~/work` both
contain that directory.

All commands accept `-C PATH` (or `--at PATH`) to select as if invoked
somewhere else:

```sh
herd list -C "$HOME/src/acme"
herd run -C "$HOME/src/acme/api" jj log -r @
```

Use `-a` or `--all-anchors` to consider every configuration file regardless
of its anchor. To operate on all configured repositories, combine it with
the filesystem root:

```sh
herd list --all-anchors -C /
herd clone --all-anchors -C /
```

When nothing is selected, `herd` says whether no anchor contained the
location or no repository was in range, and points at `--all-anchors`. An
empty selection is not an error.

Run `herd --help` or `herd <command> --help` for the complete command-line
reference, including any custom commands.

## Develop

Enter the development shell and run the test suite:

```sh
nix develop
just test
```

`just build` records the version `herd --version` reports, taking it from
`git describe` unless `HERD_VERSION` names one; release builds pass their
tag.

`treefmt` formats the Janet sources and the justfile; CI checks that the
tree is already formatted. Useful recipes are listed by `just`. Build
artifacts and locally installed JPM dependencies are stored in `build/` and
`jpm_tree/`.

## License

`herd` is licensed under [GPL-3.0-only](LICENSE).
