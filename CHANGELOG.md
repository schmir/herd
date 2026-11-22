# Changelog

## 0.6.0 - 2026-11-22

- A release archive now holds its files in a directory with the name of the
  archive, such as `herd-v0.6.0-linux-x86_64/herd`. Before, `herd` was at
  the top of the archive. The directory also holds `README.md`,
  `REFERENCE.md` and `LICENSE`. `herd self-update` reads only the new
  layout, so it cannot install version 0.5.0 or an older one. A herd of
  version 0.5.0 or older cannot update itself to this release or a later
  one: unpack the archive by hand once.
- The help of a command that takes `-f` and `-x`, such as
  `herd list --help`, now lists the configured filters, each with its
  `:doc`. A filter without a `:doc` shows its name only. `herd clone --help`
  lists only the JMESPath filters, because clone cannot use a shell filter.
- A filter written as a dictionary in `:filters` can now have a `:doc`, as
  in `{:sh "test -f Makefile" :doc "Has a Makefile."}`. Shell completion
  shows this text for the filter in place of its expression or command.
- A shell filter named with `-f` or `-x` can now take arguments, which its
  command reads as `$1`, `$2` and so on. Write `-f me-active:1w` or
  `-f 'me-active:1w 5w'`. After a single colon, spaces separate the
  arguments. After a longer run of colons, that run separates them, as in
  `-f me-active:::foo bar:::baz`. A filter name in `:filters` can no longer
  contain a colon.
- `herd tree` now refuses two lists that disagree on the URL or on an option
  of a repository, as the other commands do. Before, it printed the tree.
  Its configuration errors now name a list file by its full path.
- `:use-filters` can now name a filter as `"!name"`. This keeps the
  repositories that the filter leaves out, as `-x` does on the command line.
  A filter name in `:filters` can no longer start with `!`.
- A repository list field named `null` no longer breaks herd. It made
  `HERD_REPO_JSON` invalid JSON, and `-x` and inline lists failed with a
  decode error. This also applies to a field named `null` inside an object.
- When a list or an entry cannot be written as JSON, the error now says what
  needed it. This occurs for a number too large for a double, or a string
  that is not valid UTF-8. A filter given such a list names the filter. A
  command whose entry has such a value says that `HERD_REPO_JSON` cannot be
  written. Before, the error did not say what failed. A filter also changed
  such a string to U+FFFD. Now the filter fails.

## 0.5.0 - 2026-11-21

- `-x NAME` (or `--exclude NAME`) keeps the repositories that a filter or a
  shell command leaves out. It takes the same values as `-f`, and the two
  apply in the order they are given.
- `--show-output on-success` and `:show-output "on-success"` show the output
  of the commands that succeeded and hide the failures. The summary still
  counts the failures.
- `herd --licenses` prints the license of herd and the licenses of the code
  from Janet, spork and jpm that the binary contains. The release archives
  and the wheels also hold them, in the file `THIRD-PARTY-NOTICES`.
- A repository list entry can now carry both `clone_url` and `ssh_url`.
  `clone_url` is used, unless it is empty or null.
- The binaries now use Janet 1.43.0. A build from source no longer needs an
  installed Janet or a C compiler other than Zig.

## 0.4.7 - 2026-11-19

- `herd --version` now says "(managed by uv)" when uv installed the herd.
- `herd self-update` on a herd that uv installed now installs the latest
  release with `uv tool install --force herd-cli@latest`. It used to run
  `uv tool upgrade`, which did nothing after `herd self-update VERSION` had
  pinned the version.

## 0.4.6 - 2026-11-18

- The Linux and macOS binaries are now on PyPI as `herd-cli`. Install them
  with `uv tool install herd-cli`. `herd self-update` has uv update a herd
  that uv installed, instead of replacing the binary itself.

## 0.4.5 - 2026-11-13

- A command and a checkout filter now receive the fields of their
  repository's entry: `HERD_REPO_JSON` holds the entry as JSON, and each
  scalar field is a `HERD_FIELD_*` variable, such as `HERD_FIELD_GROUP`. A
  custom command can now branch on `:group` or `:tier` without reading the
  repository list.
- Repository list paths with a `..` component are now rejected, not only
  those that leave their anchor.
- An `:anchor` may now start with `~` or `~/`, which means `$HOME`. An
  anchor that starts with `~user` is now a configuration error, since it
  used to create a directory of that name. Start it with `./` for a
  directory of that name. Nothing else, such as `$HOME`, is expanded.

## 0.4.4 - 2026-11-10

- `:strip-components` may now name a path prefix ending in `/`. Entries that
  do not have the prefix are ignored. This can replace JP filters for simple
  path-based filtering cases.
- `herd self-update` now prints each URL it downloads and shows a progress
  bar for the release archive. A failed download reports curl's error
  message.

## 0.4.3 - 2026-11-08

- Repository lists that no `:checkouts` row reads are now ignored instead of
  being placed at `$HOME`.
- Missing repository lists and placements whose filters cannot run are shown
  as broken placements. Commands fail only when they use an affected
  placement.
- Repository list paths must stay beneath their placement anchor.

## 0.4.2 - 2026-11-07

- `herd list` now prints status, path, and clone URL in a consistent order.
- Release builds now use Ninja, and CLI tests run under several shells in
  CI.
- OpenBSD self-update now supports its `sha256` command.

## 0.4.1 - 2026-11-06

- `herd self-update` works without reading the configuration.

## 0.4.0 - 2026-11-05

- Added `herd self-update` for downloading, checking, and installing release
  binaries.
- Active repositories now show their elapsed running time.
- Checkout filters receive the same `HERD_REPO_*` environment as commands.
- Added the complete CLI reference and expanded CLI coverage.
- Added release binaries for OpenBSD and FreeBSD.

## 0.3.1 - 2026-11-01

- Added `-P` and `--no-pager` for tree output.
- Added `-c` and `--config` for selecting a configuration for one command.
- Added the `:shell` setting for choosing the shell used by commands and
  filters.
- Commands now receive repository context through `HERD_REPO_*` variables.
- Command output now goes to stdout and summaries go to stderr.
- Added terminal paging, headings, and color for command results.
- Git, SSH, and child-process behavior is now safer and more consistent in
  non-interactive runs.

## 0.3.0 - 2026-10-29

- Git is now the default VCS for checkouts.
- Added `--` support for passing arguments to custom commands.
- Added native module entry-name documentation.

## 0.2.1 - 2026-10-25

- Added `herd tree` and tree output for `herd list`.
- Trees now show checkout anchors, repository counts, nested paths, and
  placement options, with paging and color on terminals.
- Repository paths that escape their anchors or contain nested repositories
  are now rejected.

## 0.2.0 - 2026-10-25

- Misspelled top-level configuration settings are now rejected.
- Checkout rows can hold repositories inline, without a JSON list file.
- Renamed checkout configuration keys to make their purpose clearer,
  including `:checkout-defaults`, `:use-filters`, `:list`, and `:clone-url`.
- The default checkout anchor is now `$HOME` and can be disabled explicitly.
- Repository lists can now use `clone_url` as their URL field; `ssh_url`
  remains supported for compatibility.

## 0.1.0 - 2026-10-18

- Added the `run` command and completion for command and option values.
- Added shell filters alongside JMESPath filters.
- Added `--dirty` and `--clean` to select repositories by working-copy
  state.
- Added `diff` and `fetch` as default custom commands.
- Added `--sample` and `--limit` for selecting and limiting repositories.

## 0.0.9 - 2026-10-07

- Added shell completion scripts.
- `herd list` now reports repository checkout status.
- Clones are staged before installation, and blocked paths are no longer
  treated as checkouts.

## 0.0.8 - 2026-10-06

- Release binaries are now cross-compiled and tested on every supported
  target.
- Command-line flag values are validated before commands run.

## 0.0.7 - 2026-09-23

- `herd --version` now works without reading the configuration.
- Added release and test coverage for aarch64 Linux.

## 0.0.6 - 2026-09-22

- Added graceful shutdown when the terminal interrupts a run.
- Configuration and subprocess errors now receive clearer handling.
- Release builds and dependencies are pinned and tested more completely.

## 0.0.5 - 2026-09-20

- Added named JMESPath filters for repository selection.
- Added leading path-component stripping for checkout rows.
- Commands that print no output are now reported more compactly.

## 0.0.4 - 2026-09-12

- Added checkout anchor rows for configuring repository placement.
- Added the development flake-update-diff and REPL recipes.
- Build versions are now kept consistent across release artifacts.

## 0.0.3 - 2026-09-07

- Release binaries are now published as versioned tarballs.
- Linux release binaries are built against musl for broad distribution
  compatibility.

## 0.0.2 - 2026-09-07

- Added the `--version` flag and initial user documentation.
- Added support for Git and jj repositories, JSON repository metadata, and
  JDN configuration.
- Added repository selection by path and containing anchor.
- Added parallel command execution, configurable output modes, and command
  output reporting.
- Added the XDG configuration directory and support for custom commands.

## 0.0.1 - 2026-09-04

- Added release workflows that build Linux and macOS binaries and publish
  them with GitHub releases.
- Linux binaries are statically linked against musl for portability.
