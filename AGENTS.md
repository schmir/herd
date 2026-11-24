# herd development

This file provides guidance to coding agents when working with code in this
repository.

## What this is

`herd` is a CLI that runs commands across many Git/jj repositories. It is
written in Janet (`src/*.janet`) with two small C native modules
(`src/access.c`, `src/terminal.c`), and ships as a standalone binary
cross-compiled with `zig cc`. `README.md` is the user doc, `REFERENCE.md`
the command reference, `README-dev.md` the build and release process,
`GLOSSARY.md` the domain vocabulary (Repository, Anchor, Repository list,
Checkout row, Placement, Catalog, Selection, ...). Use the glossary terms in
code and docs, and respect its "Avoid" lists.

## Commands

The repo uses `jj`. Use `jj`, not `git`, for version control. In a fresh
checkout, enter the development shell with `nix develop` (or direnv), then
run `just build`. The development shell provides the tools, and the build
fetches the Janet and spork versions pinned in `pins.env`.

- `just run -- <args>`: run `src/main.janet` with the pinned Janet
  (`build/janet`, `JANET_PATH=lib`).
- `just repl [file]`: REPL inside a source file, with private bindings
  visible.
- `just build`: build the standalone `build/herd` (via ninja;
  `tools/gen-ninja.py` writes `build.ninja`).
- `just test`: build, then run every `test/*.janet` script with
  `build/janet`. Each file is a separate process; a failure names the
  script.
- Run one unit test file:
  `JANET_PATH=lib build/janet -x normal test/config.janet` (after
  `just build`).
- `just test-cli`: prysk tests in `test/cli/*.t` against `build/herd`, or
  `just test-cli path/to/herd`. One test:
  `HERD=$PWD/build/herd uv run prysk test/cli/run.t`.
- `just test-cli-shells`: the CLI tests under dash, bash, busybox and mksh
  as `sh`.
- `treefmt`: format the Janet, justfile, Markdown, Python and Nix sources.
  CI checks the formatting.
- `just ci`: format, then run both test suites.
- `just dist [platform...]`, `just archives`, `just wheels`: release builds.
  `just install` installs to `~/.local/bin/herd`.

## Architecture

- `src/main.janet` is the entry point: argument parsing (spork/argparse) and
  the subcommands. It bakes `HERD_VERSION` and `THIRD-PARTY-NOTICES` into
  the image at compile time via macros.
- The build runs `main.janet` with `build/janet` through
  `tools/make-image.janet`. That writes the marshaled image into
  `build/herd.c`. The final binary is that C, the amalgamated `janet.c` and
  the statically linked native modules. Janet's `-x normal` makes every
  compile warning an error.
- `lib/` is the module path (`JANET_PATH`). It holds the `spork` link to
  `deps/spork` and the compiled `access` and `terminal` natives. They are
  imported by bare name (`(import terminal)`), not `./terminal`. They are
  missing until a recipe has built the `natives` target.
- Configuration: `config.janet` reads `config.jdn` (the settings file:
  filters, `:checkout-defaults`, `:checkouts` rows, job count, custom
  `:commands`) plus the JSON repository lists. It builds the catalog.
- Selection pipeline: `location.janet` narrows by filesystem location, then
  `stages.janet` narrows by state (dirty/clean) and checkout filters (shell
  commands), using `named-filters.janet` and `selection.janet`. List filters
  are JMESPath expressions run by `jp`.
- Execution: `run.janet`, `clone.janet`, `survey.janet` and `sample.janet`
  do the per-repository work through `parallel.janet` (job pool with
  progress display and spinner). `process.janet` wraps subprocesses;
  commands run with `sh -c`. `vcs.janet` abstracts jj vs git (jj first for
  colocated repositories).
- Other: `tree.janet` (`herd tree`), `completions.janet`, `discover.janet`,
  `self-update.janet` (does not replace a uv-tool-installed herd).
- Tests: `test/*.janet` are unit tests, one per source module.
  `test/cli/*.t` are prysk end-to-end tests; `test/cli/setup.sh` gives each
  test its own home, config directory and local Git remotes.

## Conventions

- Add a `CHANGELOG.md` entry under `Unreleased` for user-visible changes. A
  release renames that heading to the version and date.
- Known defects and gaps go in `KNOWN-ISSUES.md`.
- Janet docstrings and comments in this repo use Simplified Technical
  English (STE100) in plain text, with no RST or Sphinx markup.
