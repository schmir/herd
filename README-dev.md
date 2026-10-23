# Developing herd

## Build

To build from source with Nix:

```sh
nix develop
just install
```

`just install` compiles the binary a release would ship for this machine and
installs it as `~/.local/bin/herd`.

Without Nix, install [Janet](https://janet-lang.org/),
[JPM](https://github.com/janet-lang/jpm), `just`, and `jj`, then run
`just build` and copy `build/herd` onto your `PATH`. `just install` and
`just dist` also need [Zig](https://ziglang.org/): they compile with
`zig cc`, against a Janet they build from source, which takes `git`, `make`
and a C compiler as well.

## Test

Enter the development shell and run the test suite:

```sh
nix develop
just test
```

`just test-cli` runs the command-line tests in `test/cli/` with
[prysk](https://www.prysk.net/) against `build/herd`, or against the binary
it is given, such as a release binary: `just test-cli path/to/herd`.

`just build` records the version `herd --version` reports, taking it from
`git describe` unless `HERD_VERSION` names one; release builds pass their
tag.

`project.janet` pins every JPM dependency to a commit, so every build
compiles the same sources. To update one, change its `:tag` and run
`just deps`.

`treefmt` formats the Janet sources and the justfile; CI checks that the
tree is already formatted. Useful recipes are listed by `just`. Build
artifacts and locally installed JPM dependencies are stored in `build/` and
`jpm_tree/`. `just dist` compiles the release binaries for every platform
with `zig cc` into `dist/`, and `just install` installs the one for this
machine.
