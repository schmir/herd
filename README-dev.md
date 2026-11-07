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
[JPM](https://github.com/janet-lang/jpm), `just`,
[ninja](https://ninja-build.org/), and `jj`, then run `just build` and copy
`build/herd` onto your `PATH`. `just install` and `just dist` also need
[Zig](https://ziglang.org/): they compile with `zig cc`, against a Janet
they build from source, which takes `git`, `make` and a C compiler as well.

## Test

Enter the development shell and run the test suite:

```sh
nix develop
just test
```

`just test-cli` runs the command-line tests in `test/cli/` with
[prysk](https://www.prysk.net/) against `build/herd`, or against the binary
it is given, such as a release binary: `just test-cli path/to/herd`.

`just build` runs `ninja host`. It records the version `herd --version`
reports, taking it from `git describe` unless `HERD_VERSION` names one;
release builds pass their tag.

`pins.jdn` pins Janet and every JPM dependency to a commit, so every build
compiles the same sources. `project.janet` and `tools/gen-ninja.janet` both
read it. To update one, change it there and run `just deps`.

`treefmt` formats the Janet sources and the justfile; CI checks that the
tree is already formatted. Useful recipes are listed by `just`. Build
artifacts and locally installed JPM dependencies are stored in `build/` and
`jpm_tree/`. `just dist` compiles the release binaries for every platform
with `zig cc` into `dist/`, and `just install` installs the one for this
machine.

`just dist` runs [ninja](https://ninja-build.org/). `tools/gen-ninja.janet`
writes `build.ninja` first, and ninja runs it again by itself when a source
file is added or removed. ninja compiles the platforms in parallel and only
recompiles what changed: after an edit to a Janet file, `janet.c` and the
native modules are not compiled again. It also notices when `HERD_VERSION`,
or else `git describe`, names another version. `just dist macos-arm64`
builds one platform. `just build` builds only `build/herd`, for this
machine.

`tools/build-deps.sh` fetches the dependencies for ninja and works around
ninja making directories inside jpm's cache; `test/build-deps.janet` tests
it with a stub `jpm`.
