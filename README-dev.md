# Developing herd

## Build

To build from source with Nix:

```sh
nix develop
just install
```

`just install` compiles the binary a release would ship for this machine and
installs it as `~/.local/bin/herd`.

Without Nix, install [Janet](https://janet-lang.org/), `just`,
[ninja](https://ninja-build.org/), [Zig](https://ziglang.org/), `git`,
`make`, a C compiler and `jj`, then run `just install`. The build compiles
with `zig cc`, against a Janet it builds from source. The Janet you install
must be the release that `pins.jdn` names.

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
reports, unless `HERD_VERSION` names one. Without it,
`uvx uv-dynamic-versioning@0.14.1` computes the version from the latest tag
with its default format, such as `0.4.6.post2+gb3ae314`, or
`0.4.6.post2.dev0+gb3ae314` when the tree has uncommitted changes. The
default adds a `v`, as in `v0.4.6.post2+gb3ae314`, so that a build of a tag
reports the tag, which `herd self-update` expects. Release builds pass their
tag.

`pins.jdn` pins Janet and spork to a commit, so every build compiles the
same sources. `tools/gen-ninja.janet` reads it. To update one, change it
there; the next build fetches it.

`treefmt` formats the Janet sources and the justfile; CI checks that the
tree is already formatted. Useful recipes are listed by `just`. Build
artifacts are stored in `build/` and `dist/`, and the spork checkout in
`deps/spork`. `just dist` compiles the release binaries for every platform
with `zig cc` into `dist/`, and `just install` installs the one for this
machine.

`just dist` runs [ninja](https://ninja-build.org/). `tools/gen-ninja.janet`
writes `build.ninja` first, and ninja runs it again by itself when a source
file is added or removed. ninja compiles the platforms in parallel and only
recompiles what changed: after an edit to a Janet file, `janet.c` and the
native modules are not compiled again. It also notices when the version
changes. `just dist macos-arm64` builds one platform. `just build` builds
only `build/herd`, a copy of the binary for this machine.

`tools/make-image.janet` runs `src/main.janet` with the host's `janet` and
writes the marshaled image, with a C `main` that runs it, into
`build/herd.c`. The native modules are compiled for the host too, so that
the host's `janet` can load them: `access` and `terminal` into `lib/`,
spork's beside its sources, which `lib/spork` links to. `lib/` is the module
path wherever the host's `janet` runs the sources: for the image, in
`just run`, `just repl` and `just test`, and in the devshell for the editor.

## Release

Before a release, rename the `Unreleased` heading in `CHANGELOG.md` to the
new version, such as `## 0.4.6 - 2026-11-18`. The release stops when the
version has no section, and the section becomes the release notes. A post
release, such as `0.4.6.post1`, needs a section of its own. A pre-release
needs none: it gets the section of the version it leads up to, or the
`Unreleased` section, or else the notes GitHub generates. Then tag the
commit and push the tag, for example `v0.4.6`. The `release` workflow runs
the tests, builds the binaries for every platform and does three things with
them, in this order:

- It creates the GitHub release as a draft, with an archive for each
  platform. This is where the BSD binaries are published.
- It publishes the Linux and macOS binaries to PyPI as the package
  `herd-cli`, so `uv tool install herd-cli` gives the command `herd`. The
  name `herd` on PyPI belongs to another project. PyPI has no tags for the
  BSDs. Before the upload, the Linux x86_64 wheel is installed and run.
- It publishes the draft.

A version on PyPI cannot be replaced, so everything that can fail comes
before the upload. If a later step fails, the release stays a draft. Run the
failed jobs again; the draft job replaces a draft that an earlier run left.

`tools/build-wheels.py` builds the wheels, one for each platform.
`HERD_VERSION=v0.4.6 just wheels` builds the binaries with `just dist` and
then the wheels. A wheel holds only the binary. The `pypi` job uses trusted
publishing, so there is no token. The project on PyPI names this repository,
the workflow `release.yml` and the GitHub environment `pypi`. The
environment needs no secrets.

A tag such as `v0.4.6rc1` makes a release candidate. Write it as PEP 440
does, without a dash, so that the wheel version matches the tag. A tag that
is not a normalized PEP 440 version, such as `v0.4.6-rc1`, stops the release
before anything is published. The GitHub release of a pre-release, which
includes a development release such as `v0.5.0.dev1`, is marked as one, so
it does not become the latest release, which `herd self-update` installs. uv
skips pre-releases unless it is told otherwise:
`uv tool install --prerelease allow herd-cli`.

`herd self-update` does not replace a herd that `uv tool` installed. It runs
`uv tool install --force` instead, with the version it is given, or with
`herd-cli@latest` when it is given none. The latter also lifts an exact pin.

A version on PyPI cannot be replaced or reused, even after it is deleted. If
a release is wrong, fix it and tag the next version.
