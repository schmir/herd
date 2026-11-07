# herd reference

`herd` runs commands across repositories described by JSON repository lists.
It supports Git and jj checkouts, parallel execution, location-based
selection, list and checkout filters, cloning, status reports, and custom
commands.

## Command line

Top-level options:

```text
-c, --config PATH   Read this configuration directory or settings file.
-V, --version       Print the build version.
-h, --help          Show help.
```

The built-in subcommands are:

### `herd clone`

Clone selected repositories that are not checked out. Existing repositories
are reported as `already checked out`; a non-empty path that is not a Git or
jj repository is `blocked`.

```text
herd clone [-C PATH] [-a] [-f NAME] [--show-output WHEN] [-j N]
```

`--show-output` is `never`, `on-failure` (the default), or `always`.

### `herd list`

Print selected repositories as tab-separated `status`, `path` and clone URL.
The status is `ok`, `missing`, `blocked`, or `extra`.

```text
herd list [-C PATH] [-a] [-f NAME] [--sample PERCENT]
           [--dirty | --clean] [--ok] [--not-ok] [--extra]
           [-t, --tree] [-P, --no-pager]
           [--max-depth N] [--hidden] [--follow-links]
```

Without `--ok`, `--not-ok`, or `--extra`, `list` prints all configured
repositories. `--ok` and `--not-ok` pick those that are ok or not, and
`--extra` discovers Git and jj repositories from the selected path or its
innermost containing repository. It reports repositories that no configured
repository names.

`--tree` renders the selected paths as a filesystem tree. Discovery options
apply only when extra repositories are requested. `-P, --no-pager` is valid
only with `--tree`.

The statuses have these meanings:

| Status    | Meaning                                               |
| --------- | ----------------------------------------------------- |
| `ok`      | The path contains a Git or jj repository.             |
| `missing` | The path does not exist or is an empty directory.     |
| `blocked` | The path contains something that is not a repository. |
| `extra`   | Discovery found a repository that no list names.      |

### `herd run`

Run a command directly in each selected checked-out repository. herd does
not pass `herd run` through a shell, so shell syntax is not interpreted. For
example, `herd run 'pwd && pwd'` tries to find a program with that name and
fails; use `herd run sh -c 'pwd && pwd'` when shell syntax is needed.

```text
herd run [-C PATH] [-a] [-f NAME] [--dirty | --clean]
         [--sample PERCENT] [--show-output WHEN]
         [-j N] [-n N] [-p, --pager | -P, --no-pager]
         CMD [CMD-ARGS...]
```

`-n, --limit N` limits the number of repositories in which the command
starts. Repositories without a command for their VCS and repositories
without a checkout do not consume the limit.

Command output is grouped per repository. `--show-output never` hides it;
`on-failure` shows output only for failures; `always` shows output for both
successes and failures. A pager is used only for colored terminal output.

### `herd tree`

Print the complete configured filesystem tree, regardless of the current
location:

```text
herd tree [-r, --repositories] [-P, --no-pager]
```

`--repositories` includes repository entries. The default tree shows the
configuration's placements and their anchors.

### `herd self-update`

Replace the running `herd` with the latest release, or with the release
`VERSION` names:

```text
herd self-update [VERSION]
```

`VERSION` is a release tag such as `v0.3.1`, or the same version without the
`v`, such as `0.3.1`. It can name an older release as well as a newer one.
Releases before the first one that has `herd self-update` cannot update
themselves again, so after installing one of them, download the next release
from the releases page instead.

`herd self-update` does not read the configuration, so a broken `config.jdn`
cannot stop it. This holds when `self-update` is the first argument.

herd asks GitHub for the release. If its tag is the version `herd --version`
reports, nothing changes. Otherwise herd downloads the archive for this
platform and the release's `SHA256SUMS` file, and checks the archive against
its checksum. It then unpacks the archive and runs the new binary with
`--version`. If that binary fails, for example because the system cannot run
it, or reports a different release, herd keeps the old binary. Otherwise
herd renames the new binary over the old one. When `herd` was started
through a symbolic link, the file the link points to is replaced and the
link stays. The download is staged in a hidden directory next to that file,
so herd must be able to write to that directory. A binary in a read-only
location, such as the Nix store, cannot update itself.

`HERD_RELEASES_URL` replaces
`https://api.github.com/repos/schmir/herd/releases` as the URL the releases
are described under. herd reads the latest release from `<URL>/latest` and a
named release from `<URL>/tags/<TAG>`, in the format of GitHub's
[releases API](https://docs.github.com/en/rest/releases/releases). herd
downloads each asset from the `browser_download_url` the description lists.
Only `https` and `file` URLs are accepted.

GitHub allows 60 API requests an hour from one address without a token, so
on a shared address the release lookup can fail with status 403 or 429. When
`GH_TOKEN` or else `GITHUB_TOKEN` holds a token, as `gh` reads them, herd
sends it with the release lookup to `https://api.github.com`, which raises
the limit. Any token works, even one granted no scopes. herd never sends it
to another host, to the asset downloads, or on curl's command line, where
other users of the machine could read it.

The command needs `curl`, `tar`, and either `sha256sum` or `shasum` on
`PATH`. Any failure exits 1 and leaves the old binary in place.

### `herd completions`

Print a completion script for one of the supported shells, or answer an
internal query from a completion script:

```text
herd completions bash|zsh|fish|commands|filters
```

`commands` and `filters` are internal subcommands. The generated completion
scripts call them to get the current subcommand and filter names. They are
not operations that run across repositories:

```text
herd completions commands   # print command names and descriptions
herd completions filters    # print filter names and expressions or commands
```

### `herd diff` and `herd fetch`

These are default custom commands. `diff` runs `git diff` or `jj diff` and
shows output through the pager. `fetch` runs `git fetch` or `jj git fetch`.
`fetch` uses `on-failure` output: successful output is hidden, and failed
output is captured and shown after the command completes. Both accept the
selection and run options used by `herd run`.

## Selection options

Every repository command selects by location. If the user does not pass `-C`
or `--at`, herd uses the current directory. It selects repositories at that
directory, below it, or containing it. This means that a command such as
`herd list` usually acts on the repositories related to the directory where
the user runs it, not on every configured repository.

The common selection options are:

```text
-C, --at PATH       Select relative to PATH (default: current directory).
-a, --all-anchors   Consider every configured anchor.
-f, --filter NAME   Apply a named filter or checkout command; repeatable.
```

`-C`, `-a`, and `-f` apply to `clone`, `list`, `run`, and custom commands.
`--sample` and `--dirty`/`--clean` apply to `list`, `run`, and custom
commands, but not `clone`. `--jobs` applies to `clone`, `run`, and custom
commands, but not `list`.

`--sample` accepts whole percentages from 1 to 100, or ranges with
`0 <= LOW < HIGH <= 100`. Either range end may be empty, so `:50` means
`0:50` and `50:` means `50:100`. The CRC-32 of each clone URL determines
membership, so the same URL is selected consistently across machines.
`--dirty` and `--clean` cannot be combined.

Use `--sample` to run a command on a repeatable subset of the selected
repositories, for example to test a change on part of a large catalog.

`--at PATH` changes the selection location. By default, only anchors that
contain that location participate. `--all-anchors` removes the anchor
restriction but still applies the location relation.

## Configuration

The default configuration directory is `$XDG_CONFIG_HOME/herd`, or
`$HOME/.config/herd`. `HERD_CONFIG` can name either a configuration
directory or a settings file. `--config PATH` selects the same kinds of
paths for one invocation. When `PATH` is a settings file, herd reads the
repository lists from that file's directory. A settings file is normally
named `config.jdn`; it uses Janet data notation. The file contains data
only. herd does not run it as code.

Use `--version` or `-V` as the first argument to show the version before
herd reads the configuration. Other commands read the configuration before
they show help. An invalid configuration can therefore make `--help` fail.

A missing configuration directory, or one that contains no repository lists,
is normal for `clone`, `run`, custom commands, and plain `list`: herd prints
a message and exits successfully. `list --extra` prints no such message and
continue with discovery. A path named by `HERD_CONFIG` or `--config` must
exist; a missing path is a configuration error.

The top-level settings are:

```janet
{:jobs 6
 :pager "less -FXR"       # false disables paging
 :shell ["sh" "-c"]
 :checkout-defaults {...}
 :checkouts [...]
 :filters {...}
 :commands {...}}
```

`:jobs` must be a positive integer. `:shell` is a non-empty argument array.
For a command string, herd builds
`[;shell command (first shell) ;arguments]`. The program name becomes `$0`,
and command arguments start at `$1`. The default is `["sh" "-c"]`.

### Repository lists and checkout rows

Every `*.json` file in the configuration directory is a repository list.
Each entry requires `path` and either `clone_url` or `ssh_url`:

```json
[
  { "path": "acme/api", "clone_url": "git@github.com:acme/api.git" },
  {
    "path": "acme/tools",
    "clone_url": "https://example.test/tools.git",
    "vcs": "jj"
  }
]
```

`vcs` is optional and is `git` by default. Valid values are `git` and `jj`.
Other entry fields are retained and may be used by filters. Entries are
validated after list filters run, so a filter can remove an entry that herd
could not use. A relative path must not leave its anchor with `..`; use an
absolute path when needed. An entry cannot contain both `clone_url` and
`ssh_url`.

`:checkouts` says where lists are placed. A row can name a file or contain
an inline array of repository objects:

```janet
{:checkout-defaults {:anchor "src"
                     :vcs "git"}
 :checkouts [{:list "projects.json"
              :anchor "work"
              :use-filters ["active"]
              :strip-components 1}
             {:list [{:path "local/tool"
                      :clone-url "https://example.test/tool.git"}]
              :anchor "/srv/repos"}]}
```

Rows inherit `:checkout-defaults`; row values override them. For `:vcs`, the
entry value has priority over the row value, and the row value has priority
over `:checkout-defaults`. A row's `:use-filters` replaces the default list;
use `[]` to clear the default filters. `:anchor` is resolved relative to
`$HOME` unless absolute. A list with no checkout row uses the defaults
alone. If no anchor is set at any level, this places the list directly under
`$HOME`. In contrast, `:anchor false` in `:checkout-defaults` disables the
default anchor. A list with no checkout row then fails with
`cannot place projects.json: the default anchor is disabled`; a row that
gives no anchor also inherits this failure. A row can still place that list
at its own anchor:

```janet
{:checkout-defaults {:anchor false}
 :checkouts [{:list "projects.json" :anchor "/srv/repos"}]}
```

`:checkout-defaults` accepts only `:anchor`, `:use-filters`, and `:vcs`.
`:anchor false` is not valid on a checkout row. `:strip-components` removes
leading path components from each list entry before placing it. A list can
be placed by multiple rows.

Inline lists use `:clone-url`, not `:ssh_url`. An inline entry with
`:ssh_url` is rejected.

Duplicate resolved paths must agree on their clone URL and repository
options; nested repositories are rejected. Missing repository list files
named by a checkout row are configuration errors.

### Filters

`:filters` maps names to either a JMESPath expression or a shell command:

```janet
{:filters {"active" ``[?archived != `true`]``
           "healthy" {:sh "test -f .healthy"}}}
```

A string entry is a JMESPath list filter. `{:jp EXPR}` is the explicit form;
`{:sh COMMAND}` defines a checkout filter. List filters run through the `jp`
executable and must return a JSON array. Checkout filters run in the
checkout and keep repositories for which the command succeeds.

`:use-filters` on a checkout row accepts list filters only. `-f` can name
list filters, checkout filters, or a shell command. `clone` accepts list
filters only; it rejects checkout filters and shell commands because it has
no checkout in which to run them. List filters reduce every configured list.
Checkout filters and command-line shell commands run in the selected
checkouts. A checkout filter keeps a repository when it exits with status
zero. Checkout filters receive the same `HERD_*` repository environment as
commands; `HERD_COLOR` is always `never` because filter output is discarded.
Multiple list filters run in the order given.

### Custom commands

`:commands` adds subcommands. A definition needs a description and either
one common command or VCS-specific commands:

```janet
{:commands {"test" {:command "make test"
                     :description "Run the test suite."
                     :show-output "on-failure"
                     :pager false}
            "status" {:command-git "git status --short"
                      :command-jj "jj status"
                      :description "Show repository status."
                      :show-output "always"}}}
```

Use `:command` for one shell command, or `:command-git` and `:command-jj`
for VCS-specific commands. If omitted, `:show-output` defaults to
`on-failure`, and `:pager` defaults to `false`. `:show-output` accepts
`never`, `on-failure`, or `always`; `:pager` is a boolean. The protected
built-in commands are `clone`, `list`, `run`, `tree`, and `completions`;
they cannot be replaced. `diff` and `fetch` are default custom commands that
herd supplies. When a repository has both `.git` and `.jj`, herd uses jj. A
VCS-specific command is skipped when that repository has no command for its
detected VCS.

Arguments for a custom command come after `--`:

Example:

```janet
{:commands {"say" {:command "printf '<%s>\\n' \"$@\""
                    :description "Print command arguments."
                    :show-output "always"}}}
```

Run it as follows:

```text
herd say -- "first value" --help ""
```

For a configured command, herd passes these arguments to the shell as
positional parameters. It does not add them to the command string. Use `$1`,
`$2`, or `"$@"` in the command. `"$@"` keeps each argument as a separate
value, including values that contain spaces or begin with `-`. The command
receives three arguments in the example: `first value`, `--help`, and an
empty string. The `--` separator belongs to herd and is not passed to the
command. Arguments before `--` are herd options. Without `--`, a command
argument that is not a herd option is rejected.

A configured definition for `diff` or `fetch` replaces its default
definition.

## Command environment

Commands and checkout filters run with the repository as their working
directory and receive:

| Variable            | Meaning                                                 |
| ------------------- | ------------------------------------------------------- |
| `HERD_COLOR`        | `always` for colored terminal output, otherwise `never` |
| `HERD_CONFIG`       | Absolute path of the configuration in use               |
| `HERD_AT_PATH`      | Resolved selection location                             |
| `HERD_REPO_RELPATH` | Repository path relative to `HERD_AT_PATH`              |
| `HERD_REPO_ANCHOR`  | First configured anchor, or empty                       |
| `HERD_REPO_PATH`    | Repository path as written beneath its anchor           |
| `HERD_REPO_URL`     | Configured clone URL                                    |
| `HERD_REPO_VCS`     | Detected `git` or `jj`                                  |

`NO_COLOR` disables terminal color. herd sets Git and ssh no-prompt
defaults, but values already present in the environment take precedence. A
program can still open the terminal itself, so these settings do not prevent
every possible prompt. Child standard input is closed unless the operation
supplies another input.

## Exit behavior

Configuration and usage errors exit 1. An empty selection is not an error
and exits 0. This includes a location with no containing anchor and filters
that remove every repository. A selection error exits 1, for example when a
checkout filter fails with status 127.

A run with any failed repository exits 1. `clone` also exits 1 when a
repository is blocked or its clone fails. A repository that is not checked
out is reported as `not checked out` and does not stop other repositories. A
repository with no matching VCS-specific command is reported as `skipped`.
The first Ctrl-C starts no further repositories, lets active operations
finish, and then exits 130. A second Ctrl-C exits 130 immediately.
