"""Write build.ninja, which cross-compiles herd for every platform.

    uv run --no-project python tools/gen-ninja.py && ninja   # all platforms
    ninja macos-arm64                                        # one platform
    ninja host                     # build/herd for this machine
    ninja natives                  # build/janet and what src/ needs

ninja needs HERD_VERSION in the environment, and the build stops without it.
just sets it, so use HERD_VERSION=v0.4.6 ninja host when you run ninja
without just.

just dist does the first. ninja has no globs, so this script lists the
sources it finds. build.ninja depends on the directories they live in, which
change when a file is added or removed, so ninja runs this script again by
itself when that happens.

This script is Python and not Janet because the build makes the Janet it
uses. It reads the commits from pins.env itself, not from the environment,
so that ninja writes the right commits when it runs this script without just.

The steps:

  1. spork is checked out into deps/spork, and Janet into dist/janet-COMMIT.
     Janet's own boot step makes janet.c, which is compiled for the host into
     build/janet. Each happens once per pinned commit.
  2. The native modules are compiled for the host, so that build/janet can
     load them: herd's into lib/, spork's beside spork's sources.
  3. build/janet runs tools/make-image.janet, which runs src/main.janet and
     writes the marshaled image to build/herd.c.
  4. Each platform compiles janet.c, the image and every native module with
     zig cc, and links them. A platform recompiles only what changed, and
     ninja runs the platforms in parallel. build/herd is a copy of the binary
     for this machine.
"""

import platform
import re
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

# Name and zig target.
PLATFORMS = [
    ("linux-x86_64", "x86_64-linux-musl"),
    ("linux-aarch64", "aarch64-linux-musl"),
    ("macos-arm64", "aarch64-macos.11.0"),
    ("macos-x86_64", "x86_64-macos.11.0"),
    ("openbsd-arm64", "aarch64-openbsd.7.8"),
    ("openbsd-amd64", "x86_64-openbsd.7.8"),
    ("freebsd-arm64", "aarch64-freebsd.14.0"),
    ("freebsd-amd64", "x86_64-freebsd.14.0"),
]

# The release platform for platform.system() and platform.machine(). It has
# to give the names that the table in src/platform.janet gives, which herd
# self-update uses.
HOST_PLATFORMS = {
    ("Linux", "x86_64"): "linux-x86_64",
    ("Linux", "aarch64"): "linux-aarch64",
    ("Linux", "arm64"): "linux-aarch64",
    ("Darwin", "arm64"): "macos-arm64",
    ("Darwin", "x86_64"): "macos-x86_64",
    ("OpenBSD", "amd64"): "openbsd-amd64",
    ("OpenBSD", "arm64"): "openbsd-arm64",
    ("OpenBSD", "aarch64"): "openbsd-arm64",
    ("FreeBSD", "amd64"): "freebsd-amd64",
    ("FreeBSD", "arm64"): "freebsd-arm64",
    ("FreeBSD", "aarch64"): "freebsd-arm64",
}

PROGRAM = "herd"
HOST_JANET = "build/janet"
SPORK_DIR = "deps/spork"
SPORK_STAMP = SPORK_DIR + ".commit"


# The native modules src/main.janet loads, by import name, with their sources.
# Linked into one binary, their entry functions would clash, so each is
# compiled with JANET_ENTRY_NAME set to the name entry_name gives.
MODULES = [
    ("access", "src/access.c"),
    ("terminal", "src/terminal.c"),
    ("spork/crc", f"{SPORK_DIR}/src/crc.c"),
    ("spork/json", f"{SPORK_DIR}/src/json.c"),
    ("spork/rawterm", f"{SPORK_DIR}/src/rawterm.c"),
]


class Ninja:
    """The lines of a build.ninja, written one rule and one edge at a time."""

    def __init__(self) -> None:
        """Start with no lines."""
        self.lines: list[str] = []

    def line(self, text: str = "") -> None:
        """Add one line."""
        self.lines.append(text)

    def rule(self, name: str, command: str, **variables: str) -> None:
        """Add a rule, and a blank line after it."""
        self.line(f"rule {name}")
        self.line(f"  command = {command}")
        for key, value in variables.items():
            self.line(f"  {key} = {value}")
        self.line()

    def build(
        self,
        outputs: list[str],
        rule: str,
        explicit: Sequence[str] = (),
        implicit: Sequence[str] = (),
        order_only: Sequence[str] = (),
        **variables: str,
    ) -> None:
        """Add an edge."""
        text = f"build {' '.join(outputs)}: {' '.join([rule, *explicit])}"
        if implicit:
            text += " | " + " ".join(implicit)
        if order_only:
            text += " || " + " ".join(order_only)
        self.line(text)
        for key, value in variables.items():
            self.line(f"  {key} = {value}")

    def text(self) -> str:
        """Return the file."""
        return "\n".join(self.lines) + "\n"


@dataclass(frozen=True)
class Janet:
    """The paths of the pinned Janet checkout and what the build makes in it."""

    commit: str

    @property
    def dir(self) -> str:
        """Return the checkout. Its path names the commit."""
        return f"dist/janet-{self.commit}"

    @property
    def makefile(self) -> str:
        """Return Janet's Makefile, which runs the boot step."""
        return f"{self.dir}/Makefile"

    @property
    def shell(self) -> str:
        """Return the C main of the janet executable."""
        return f"{self.dir}/src/mainclient/shell.c"

    @property
    def c(self) -> str:
        """Return the amalgamated janet.c that the boot step makes."""
        return f"{self.dir}/build/c/janet.c"

    @property
    def h(self) -> str:
        """Return the janet.h that the boot step makes."""
        return f"{self.dir}/build/janet.h"


def read_pins(path: Path) -> dict[str, str]:
    """Return the KEY=value lines of path. Skip blank lines and # comments."""
    pins = {}
    for number, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep:
            sys.exit(f"gen-ninja: {path}:{number}: expected KEY=value, not {line!r}")
        pins[key] = value
    return pins


def commit(pins: dict[str, str], key: str) -> str:
    """Return the commit that pins names under key, which must be a full hash."""
    value = pins.get(key, "")
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        sys.exit(f"gen-ninja: pins.env needs a 40 digit commit hash for {key}, not {value!r}")
    return value


def entry_name(name: str) -> str:
    """Return the name of the entry function of the native module name.

    jpm makes it so: janet_module_entry_ and the name, with each byte that is
    not a letter, digit or _ written as _<decimal code>_. entry-name in
    tools/make-image.janet must give the same name, because the image
    registers each module under it.
    """
    out = "janet_module_entry_"
    for b in name.encode():
        c = chr(b)
        out += c if c.isascii() and (c.isalnum() or c == "_") else f"_{b}_"
    return out


def host_module(name: str) -> str:
    """Return where the host's native module name goes.

    spork's go beside spork's sources, which lib/spork links to, and herd's
    go in lib/.
    """
    if name.startswith("spork/"):
        return f"{SPORK_DIR}/{name}.so"
    return f"lib/{name}.so"


def write_rules(n: Ninja, janet: Janet, host_os: str, host_machine: str) -> None:
    """Add the rules."""
    n.rule(
        "regen",
        "uv run --no-project python tools/gen-ninja.py",
        description="regenerating build.ninja",
        generator="1",
    )
    # The version HERD_VERSION names, as the justfile exports it. The rule
    # fails when HERD_VERSION is not set. The version is kept in a file that
    # is rewritten only when it changes, and restat tells ninja that, so
    # nothing that depends on it runs for nothing.
    n.rule(
        "version",
        'mkdir -p build && v="$${HERD_VERSION:?run ninja through just, which sets HERD_VERSION}"'
        ' && { [ "$$(cat $out 2>/dev/null)" = "$$v" ] || printf \'%s\\n\' "$$v" > $out; }',
        description="version",
        restat="1",
    )
    n.rule(
        "spork",
        "bash tools/fetch-spork.sh $dir $commit",
        description="fetching spork $commit",
        restat="1",
    )
    # A module is loaded by build/janet, which resolves the Janet functions it
    # calls; macOS has to be told to leave them for then.
    lookup = " -undefined dynamic_lookup" if host_os == "Darwin" else ""
    n.rule(
        "so",
        f"cc -shared -fPIC -O2 -I{janet.dir}/build{lookup} -MD -MF $out.d -o $out $in",
        description="so $out",
        depfile="$out.d",
        deps="gcc",
    )
    # The list of inputs is part of the command, as the argument of the no-op
    # built-in `:`. ninja only sees an input become newer, never one
    # disappear, and runs a step again when its command changes. Without
    # this, deleting or renaming a source file would leave the old image in
    # place.
    n.rule(
        "image",
        ': $inputs && HERD_VERSION="$$(cat build/version)" JANET_PATH=lib'
        f" {HOST_JANET} tools/make-image.janet src/main.janet $out $natives",
        description="image $out",
    )
    # The Janet steps keep what is already there, and restat tells ninja when
    # they did. A restored CI cache has the checkout and janet.c but no ninja
    # log, so ninja runs them again. Their paths name the commit, so a change
    # of the pin starts from a new directory. ninja makes that directory
    # before the fetch, so the fetch removes it when the checkout is not
    # complete.
    n.rule(
        "janet-fetch",
        "test -f $dir/Makefile || { rm -rf $dir && git init -q $dir"
        " && git -C $dir fetch -q --depth 1 https://github.com/janet-lang/janet.git $commit"
        " && git -C $dir -c advice.detachedHead=false checkout -q FETCH_HEAD; }",
        description="fetching janet $commit",
        restat="1",
    )
    # Nix's compiler wrapper fortifies what it compiles, and Janet builds its
    # bootstrap with -O0, which glibc warns about once per file. The bootstrap
    # only writes janet.c, so build it without fortification. The wrapper
    # reads its hardening from NIX_HARDENING_ENABLE, which nothing outside Nix
    # reads.
    n.rule(
        "janet-boot",
        'NIX_HARDENING_ENABLE="$$(for f in $${NIX_HARDENING_ENABLE-}; do'
        " case $$f in fortify|fortify3) ;; *) printf '%s ' $$f ;; esac; done)\""
        " make -s -C $dir -j$$(getconf _NPROCESSORS_ONLN) build/c/janet.c build/janet.h",
        description="building janet.c",
        restat="1",
    )
    # -rdynamic exports the Janet functions, so that the native modules find
    # them.
    ldl = " -ldl" if host_os == "Linux" else ""
    n.rule(
        "host-janet",
        f"cc -std=c99 -O2 -fvisibility=hidden -rdynamic -I{janet.dir}/build -o $out $in -lm -lpthread{ldl}",
        description="cc $out",
    )
    n.rule(
        "cc",
        f"zig cc -target $target -O2 -I{janet.dir}/build $flags -MD -MF $out.d -c $in -o $out",
        description="cc $target $out",
        depfile="$out.d",
        deps="gcc",
    )
    n.rule(
        "link",
        "zig cc -target $target -s -o $out $in -lm -lpthread",
        description="link $out",
    )
    # The check makes sure that the binary reports the version. The check job
    # in .github/workflows/test.yml does the same for each release binary.
    n.rule(
        "host",
        'cp $in $out && test "$$($out --version)" = "herd $$(cat build/version)"',
        description="host $out",
    )
    n.rule(
        "no-host",
        f"echo 'no release binary is built for {host_os}-{host_machine}' >&2 && false",
        description="host",
    )


def write_host_steps(n: Ninja, janet: Janet, spork_commit: str) -> None:
    """Add the edges that run on the host: the checkouts, build/janet, the native modules and the image."""
    # Run again when a file is added or removed in these directories.
    n.build(["build.ninja"], "regen", implicit=["tools/gen-ninja.py", "pins.env", "src"])
    n.line()
    # Never exists, so whatever depends on it is always out of date.
    n.build(["FORCE"], "phony")
    n.build(["build/version"], "version", ["FORCE"])
    spork_sources = [source for name, source in MODULES if name.startswith("spork/")]
    n.build(
        [SPORK_STAMP, *spork_sources],
        "spork",
        implicit=["tools/fetch-spork.sh"],
        dir=SPORK_DIR,
        commit=spork_commit,
    )
    n.build([janet.makefile, janet.shell], "janet-fetch", dir=janet.dir, commit=janet.commit)
    n.build([janet.c, janet.h], "janet-boot", [janet.makefile], dir=janet.dir, commit=janet.commit)
    n.build([HOST_JANET], "host-janet", [janet.c, janet.shell], [janet.h])
    n.line()

    host_modules = [host_module(name) for name, _ in MODULES]
    for name, source in MODULES:
        n.build([host_module(name)], "so", [source], [janet.h])
    n.build(["natives"], "phony", [HOST_JANET, *host_modules], [SPORK_STAMP])
    # The program the image is made from.
    image_inputs = sorted(str(p) for p in Path("src").iterdir() if p.suffix == ".janet")
    n.build(
        ["build/herd.c"],
        "image",
        image_inputs,
        [
            "tools/make-image.janet",
            "THIRD-PARTY-NOTICES",
            "build/version",
            HOST_JANET,
            SPORK_STAMP,
            *host_modules,
        ],
        inputs=" ".join(image_inputs),
        natives=" ".join(name for name, _ in MODULES),
    )
    n.line()


def write_platform(n: Ninja, janet: Janet, name: str, target: str) -> str:
    """Add the edges that compile and link the binary for one platform, and return its path."""
    objs = []

    def compile_one(source: str, stem: str, flags: str = "") -> None:
        obj = f"dist/{name}/obj/{stem}.o"
        objs.append(obj)
        n.build([obj], "cc", [source], [janet.h], target=target, flags=flags)

    compile_one(janet.c, "janet")
    compile_one(f"build/{PROGRAM}.c", PROGRAM)
    for module, source in MODULES:
        compile_one(source, Path(source).stem, f"-DJANET_ENTRY_NAME={entry_name(module)}")
    exe = f"dist/{name}/{PROGRAM}"
    n.build([exe], "link", objs, target=target)
    n.build([name], "phony", [exe])
    n.line()
    return exe


def main() -> None:
    """Write build.ninja in the current directory, which is the project root."""
    pins = read_pins(Path("pins.env"))
    janet = Janet(commit(pins, "JANET_COMMIT"))
    host_os, host_machine = platform.system(), platform.machine()

    n = Ninja()
    n.line("# Generated by tools/gen-ninja.py. Do not edit.")
    n.line("ninja_required_version = 1.10")
    n.line()
    write_rules(n, janet, host_os, host_machine)
    write_host_steps(n, janet, commit(pins, "SPORK_COMMIT"))
    exes = {name: write_platform(n, janet, name, target) for name, target in PLATFORMS}

    host_platform = HOST_PLATFORMS.get((host_os, host_machine))
    if host_platform:
        n.build(["build/herd"], "host", [exes[host_platform]], ["build/version"])
        n.build(["host"], "phony", ["build/herd"])
    else:
        # Without this, ninja would only say that host is an unknown target.
        n.build(["host"], "no-host")
    n.build(["all"], "phony", list(exes))
    n.line("default all")

    # Always written, also when nothing changed: ninja runs this script when
    # an input is newer than build.ninja, and then build.ninja must become
    # newer, or ninja runs the script again until it gives up.
    Path("build.ninja").write_text(n.text())


if __name__ == "__main__":
    main()
