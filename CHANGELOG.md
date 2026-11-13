# Changelog

## Unreleased

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
