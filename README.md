# herd

`herd` manages a set of source code repositories. The repositories can use
[Jujutsu](https://jj-vcs.github.io/jj/latest/) or Git. `herd` can clone
missing working copies, fetch remotes, and run a command in selected
repositories.

## Install

Binaries are available for these platforms:

| Platform        | System          |
| --------------- | --------------- |
| `linux-x86_64`  | Linux on x86-64 |
| `linux-aarch64` | Linux on ARM64  |
| `macos-arm64`   | macOS on ARM64  |

Download the binaries from the
[releases page](https://github.com/schmir/herd/releases/latest). Each
release has one `herd-<version>-<platform>.tar.gz` archive for each
platform. The table shows the `<platform>` values. Each archive contains one
executable file named `herd`. The Linux binaries are static. They do not
need a C library on the target system.

Extract the archive:

```sh
tar xzf herd-v1.2.3-macos-arm64.tar.gz
```

Install the executable on your `PATH`:

```sh
install -m 755 herd ~/.local/bin/herd
```

On macOS, the `herd` executable can have the quarantine attribute. If `herd`
has this attribute, macOS does not run `herd`. Remove the attribute:

```sh
xattr -d com.apple.quarantine ~/.local/bin/herd
```

Use `herd --version` to show the release version. To clone and fetch
repositories, also install `jj` or `git`. Make sure that the applicable
command is on your `PATH`.

To build `herd` from source with Nix:

```sh
nix develop
just build
install -m 755 build/herd ~/.local/bin/herd
```

To build without Nix, install these tools:

- [Janet](https://janet-lang.org/)
- [JPM](https://github.com/janet-lang/jpm)
- `just`
- `jj`

Then, run `just build`.

## Configure

`herd` reads its configuration from `$XDG_CONFIG_HOME/herd`. If
`XDG_CONFIG_HOME` is not set, it reads the configuration from
`~/.config/herd`.

### Repositories

`herd` reads all `*.json` files in the configuration directory. Each JSON
file defines a set of repositories and their locations in a directory tree:

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

The `path` and `ssh_url` values are required strings. The `ssh_url` value
identifies the remote repository. The `path` value sets its location in each
configured directory tree. `herd` resolves a relative path from the checkout
anchor. It uses an absolute path without changes. For more information, see
[Anchors](#anchors).

The optional `vcs` value is `"jj"` or `"git"`. This value specifies how
`herd clone` checks out the repository. For more information, see
[Version control](#version-control).

### Configure repository checkouts

Use checkout settings to specify where and how `herd` checks out the
repositories in a JSON file. Add a `config.jdn` file to the configuration
directory. Use `:defaults` and `:checkouts` in this file:

```janet
{:defaults {:anchor "src" :vcs "jj"}

 :checkouts
 [{:from "work.json"   :anchor "work"}
  {:from "work.json"   :anchor "/srv/review" :vcs "git"}
  {:from "vendor.json" :anchor "/opt/vendor" :vcs "git"}]}
```

Each row in the `:checkouts` array contains checkout settings for one JSON
file. The required `:from` value must identify a file in the configuration
directory. If it does not, `herd` reports an error. The optional `:anchor`
value sets the base directory for relative repository paths. The optional
`:vcs` value selects Jujutsu or Git.

Each row uses the values in `:defaults`. A value in the row replaces the
related default value. If no row refers to a JSON file, `herd` checks out
its repositories one time with only the default values. Therefore, you do
not have to add a row for each JSON file.

#### Anchors

The `:anchor` value in a row is the base directory for relative paths in its
configuration file. `herd` resolves a relative `:anchor` value from `$HOME`.
For example, the first row sets the anchor for `work.json` to `$HOME/work`.
The path `team/api` in that file becomes `$HOME/work/team/api`.

`herd` uses an anchor only with a relative `path` value. It does not change
an absolute `path` value. The repository directory does not have to exist
before you run `herd clone`.

`herd` gets the anchor from the first applicable level in this table:

| Level         | Location                        |
| ------------- | ------------------------------- |
| the checkout  | `:anchor` in a `:checkouts` row |
| all checkouts | `:anchor` in `:defaults`        |

If no level sets the value, `herd` uses `$HOME`. `herd` reports an error if
it must resolve a relative anchor and `HOME` is not set.

More than one row can refer to the same JSON file. Each row creates a set of
repository locations below its anchor. In the example, the `team/api` entry
in `work.json` identifies these two locations:

- `$HOME/work/team/api`
- `/srv/review/team/api`

`herd clone` checks out the repository at both locations. An absolute
repository path is the same for all anchors. `herd` checks out that
repository one time only.

#### Version control

The `:vcs` value selects the version control system (VCS). It specifies how
`herd clone` checks out a repository. Use `"jj"` for a working copy that
Jujutsu and Git share. Use `"git"` for a plain Git working copy.

You can set this value at three levels. The setting at the first applicable
level in this table has priority:

| Level          | Location                           |
| -------------- | ---------------------------------- |
| the repository | `"vcs"` in a JSON repository entry |
| the checkout   | `:vcs` in a `:checkouts` row       |
| all checkouts  | `:vcs` in `:defaults`              |

If no level sets the value, `herd` uses `jj`.

Use the checkout level when the location, and not the repository, must set
the VCS. In the example settings, one `team/api` entry in `work.json`
creates two types of working copy. The working copy at `$HOME/work/team/api`
uses Jujutsu. The working copy at `/srv/review/team/api` uses plain Git. If
the repository entry has `"vcs": "git"`, both working copies use Git.

### Configure parallel operations

The default number of operations that run at the same time is 6. Use `:jobs`
in `config.jdn` to set a different number:

```janet
{:jobs 12}
```

The `-j` and `--jobs` options replace this value for one command. For more
information, see [Use](#use).

### Custom commands

Each entry in `:commands` adds a subcommand. The subcommand has the same
options as `herd run`. `herd --help` shows the value of `:description`:

```janet
{:commands
 {"update" {:command "jj git fetch && jj up"
            :description "Fetch and update each repository."}
  "status" {:command-git "git status --short"
            :command-jj "jj st"
            :description "Show the working-copy status."
            :show-output "always"}}}
```

Each entry needs a `:description` string. If an entry has no description,
`herd` reports an error. Each entry also needs a command. You can define one
`:command` string. As an alternative, you can define `:command-git` and
`:command-jj` strings. `herd` selects the applicable command from the
contents of the repository. A `.jj` directory selects the Jujutsu command. A
`.git` directory selects the Git command. If there is no command for the
detected VCS, `herd` skips the repository.

Commands run through `sh -c`. You can use shell operators such as pipes and
`&&`. The `:show-output` value sets the default output condition for the
command. For more information, see [Use](#use). A custom command cannot have
the same name as a built-in command.

## Use

To list the selected repositories, run:

```sh
herd list
```

A tab character separates the path and the URL in each output line. The list
includes repositories that are not checked out. You can use the output as
input for scripts:

```
/home/you/src/acme/api	git@github.com:acme/api.git
/home/you/src/acme/web	git@github.com:acme/web.git
```

To clone missing repositories, run:

```sh
herd clone
```

`herd clone` uses the checkout settings to create working copies that
Jujutsu and Git share, or plain Git working copies. If a target directory
exists and contains files, `herd` does not change it. The command shows a
summary when it is complete. It returns an exit status that is not zero if a
clone fails:

```
2 cloned, 1 already checked out, 0 failed
```

To fetch the Git remotes of all checked-out repositories, run:

```sh
herd fetch
```

To run a command in all checked-out repositories, run:

```sh
herd run jj st
herd run --show-output always git remote -v
```

`herd` uses each repository as the working directory for the command. The
`--show-output` option accepts `never`, `on-failure`, or `always`. The
default is `on-failure`. A successful command does not show its output. A
failed command shows its output.

`herd` captures the output separately for each repository. It shows each
result as one block. Output from parallel operations is easy to read:

```
✓ /home/you/src/acme/api
| stdout
|   origin	git@github.com:acme/api.git (fetch)
|   origin	git@github.com:acme/api.git (push)
```

The heading for a failed command starts with `✗` and includes its exit
status.

Commands cannot read terminal input. Make sure that each command runs
without it. The `run`, `fetch`, and custom commands show a summary when they
are complete. They return an exit status that is not zero if a command
fails:

```
3 succeeded, 0 failed, 0 skipped, 1 not checked out
```

`herd` skips repositories that are not checked out. It does not count them
as failures. You can use `herd run` before you clone all repositories.

The `clone`, `fetch`, `run`, and custom commands accept `-j N` or
`--jobs N`. Use this option to change the number of repositories that `herd`
processes at the same time:

```sh
herd clone -j 12
```

## Selection

Commands select repositories relative to the current directory. A repository
must match the path condition and the anchor condition.

The path condition selects a repository in these cases:

- The repository is in or below the current directory.
- The repository contains the current directory.

`herd` selects a repository from any directory in its working copy.

The anchor condition selects repositories only from anchors that contain the
current directory. This condition makes sure that a command in `/` does not
select unrelated groups of repositories.

For example, use this configuration:

```
~/.config/herd/personal.json          anchored at ~
~/.config/herd/work.json              anchored at ~/work
~/.config/herd/config.jdn             {:checkouts [{:from "work.json" :anchor "work"}]}
```

If you run `herd list` in `~`, it selects only repositories from
`personal.json`. The `~/work` anchor does not contain `~`. If you run the
command in `~/work/team/api`, it selects repositories from both files. The
`~` and `~/work` anchors both contain that directory.

All commands accept `-C PATH` or `--at PATH`. Use this option to select
repositories relative to a different directory:

```sh
herd list -C "$HOME/src/acme"
herd run -C "$HOME/src/acme/api" jj log -r @
```

Use `-a` or `--all-anchors` to include all configuration files. This option
ignores their anchors. To operate on all configured repositories, also set
the path to the file-system root:

```sh
herd list --all-anchors -C /
herd clone --all-anchors -C /
```

If the selection is empty, `herd` gives the reason. It tells you if no
anchor contains the location or if no repository is in the applicable path.
It also refers to `--all-anchors`. An empty selection is not an error.

For the full command-line reference, run `herd --help` or
`herd <command> --help`. The help also includes custom commands.

## Develop

Enter the development shell:

```sh
nix develop
```

Run the test suite:

```sh
just test
```

The `just build` command records the version that `herd --version` shows. By
default, it gets the version from `git describe`. Set `HERD_VERSION` to use
a different version. Release builds set this variable to their tag.

The `treefmt` command formats the Janet source files and the justfile. CI
checks that these files have the correct format. Run `just` to list the
recipes. Build artifacts are in `build/`. JPM installs its local
dependencies in `jpm_tree/`.

## License

`herd` uses the [GPL-3.0-only](LICENSE) license.
