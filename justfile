set shell := ["bash", "-euo", "pipefail", "-c"]

# Export the build version so all recipes that invoke jpm use the same value.
export HERD_VERSION := env_var_or_default("HERD_VERSION", `git describe --tags --always --dirty 2>/dev/null || echo dev`)

# Janet 1.41.2, which the release binaries are cross-compiled from.
janet_commit := "0fea20c82182fe661f75b00a8889d801fe2d79b6"

# Show the available project commands.
default:
    @just --list

# Install the dependencies project.janet pins in the local JPM tree.
deps:
    jpm --local deps

# Janet looks for a native module by bare name on the module path, and jpm
# adds build/ to it only for the builds and test runs it drives itself. These
# two recipes run the interpreter directly, so they say where to look, and
# they build first so there is something there to find.
native_path := '(array/insert module/paths 1 ["build/:all:.so" :native])'

# Run the program.
run *args: build
    jpm --local janet -e '{{ native_path }}' -- src/main.janet {{ args }}

# Start a REPL inside a source file, private bindings included.
repl file="src/main.janet": build
    jpm --local janet -e '{{ native_path }}' -e '(repl nil nil (dofile "{{ file }}"))'

# Build the standalone executable in build/.
build *args: deps
    #!/usr/bin/env bash
    set -euo pipefail
    # JPM does not track HERD_VERSION. Remove all outputs when the executable
    # has a different version so JPM regenerates the versioned sources.
    if [[ ! -x build/herd \
          || "$(build/herd --version 2>/dev/null || true)" != "herd $HERD_VERSION" ]]; then
        rm -f build/herd build/herd.c build/*.o
    fi
    jpm --local build {{ args }}
    # Apply the same version check as the release workflow.
    test "$(build/herd --version)" = "herd $HERD_VERSION"

# Run the test suite in test/.
test: deps
    jpm --local test

# The prysk the command-line tests run with. The release workflow's check job
# names the same version.
prysk := "prysk==0.20.0"

# Name a release binary to test what ships.
[doc('Run the command-line tests in test/cli/ against build/herd or the binary named.')]
test-cli herd="":
    #!/usr/bin/env bash
    set -euo pipefail
    herd="{{ herd }}"
    if [[ -z "$herd" ]]; then
        just build
        herd=build/herd
    fi
    [[ "$herd" == /* ]] || herd="$PWD/$herd"
    HERD="$herd" uvx {{ prysk }} test/cli/

# The server evaluates a file and its imports to find definitions, so a module
# path that misses spork or the native access and terminal modules makes every
# lookup answer null. See .janet-path/README.md. Needs the devshell for janet-lsp and the
# JANET_PATH it relies on.
[doc('Check that janet-lsp finds a definition in config.janet.')]
[extension('.py')]
check-lsp: build
    #!/usr/bin/env -S uv run --script
    # /// script
    # dependencies = ["pytest"]
    # ///
    import json
    import shutil
    import subprocess
    import sys
    from pathlib import Path

    import pytest

    ROOT = Path.cwd()
    SOURCE = ROOT / "src" / "config.janet"

    pytestmark = pytest.mark.skipif(
        shutil.which("janet-lsp") is None, reason="janet-lsp is not on PATH"
    )


    def test_definition_of_a_function_defined_in_the_same_file():
        """Asking for a called function's definition finds its defn."""
        text = SOURCE.read_text()
        lines = text.split("\n")
        defn = next(i for i, l in enumerate(lines) if "(defn merge-repository-lists" in l)
        call = next(i for i, l in enumerate(lines) if l.strip() == "(merge-repository-lists")
        uri = SOURCE.as_uri()

        server = subprocess.Popen(
            ["janet-lsp"],
            cwd=ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )

        def send(message):
            body = json.dumps({"jsonrpc": "2.0", **message}).encode()
            server.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
            server.stdin.flush()

        def receive_until(wanted):
            while True:
                length = 0
                while (line := server.stdout.readline()) not in (b"\r\n", b""):
                    if line.lower().startswith(b"content-length"):
                        length = int(line.split(b":")[1])
                if wanted(message := json.loads(server.stdout.read(length))):
                    return message

        try:
            send({"id": 1, "method": "initialize", "params": {
                "processId": None, "rootUri": ROOT.as_uri(), "capabilities": {}}})
            receive_until(lambda m: m.get("id") == 1)
            send({"method": "initialized", "params": {}})
            send({"method": "textDocument/didOpen", "params": {"textDocument": {
                "uri": uri, "version": 0, "languageId": "janet", "text": text}}})
            # The server has evaluated the file once it reports diagnostics for it.
            diagnostics = receive_until(
                lambda m: m.get("method") == "textDocument/publishDiagnostics"
            )
            assert diagnostics["params"]["diagnostics"] == []

            column = lines[call].index("merge-repository-lists") + 3
            send({"id": 2, "method": "textDocument/definition", "params": {
                "textDocument": {"uri": uri},
                "position": {"line": call, "character": column}}})
            result = receive_until(lambda m: m.get("id") == 2)["result"]
        finally:
            server.kill()

        assert result is not None
        assert result["range"]["start"]["line"] == defn


    if __name__ == "__main__":
        sys.exit(pytest.main([__file__, "-q", "-rs"]))

# Format the tree and run both test suites.
ci: && test test-cli
    treefmt

# The platforms are linux-x86_64, linux-aarch64, macos-arm64 and macos-x86_64.
#
# jpm's own build runs src/main.janet with the host janet and writes the
# marshaled image into build/herd.c. That step has to run here, since it loads
# native modules, but what it writes is portable C. Only the final compile needs
# the target, and that is plain C: herd.c, the amalgamated janet.c, and every
# native module the image registers, built in statically.
[doc('Cross-compile release binaries with zig cc, for the platforms named or all four.')]
dist *platforms: build
    #!/usr/bin/env bash
    set -euo pipefail
    known=(linux-x86_64 linux-aarch64 macos-arm64 macos-x86_64)
    # The zig target for a platform, or nothing for one there is no build of.
    target_of() {
        case "$1" in
            linux-x86_64) echo x86_64-linux-musl ;;
            linux-aarch64) echo aarch64-linux-musl ;;
            macos-arm64) echo aarch64-macos.11.0 ;;
            macos-x86_64) echo x86_64-macos.11.0 ;;
        esac
    }
    platforms=({{ platforms }})
    if [[ ${#platforms[@]} -eq 0 ]]; then
        platforms=("${known[@]}")
    fi
    for platform in "${platforms[@]}"; do
        if [[ -z "$(target_of "$platform")" ]]; then
            echo "Unknown platform $platform; known are ${known[*]}" >&2
            exit 1
        fi
    done
    out=dist
    janet_src="$out/janet-{{ janet_commit }}"
    # janet.c is generated by Janet's own boot step, which runs on the host,
    # so build it once per pinned commit.
    if [[ ! -f "$janet_src/build/c/janet.c" ]]; then
        rm -rf "$janet_src"
        git init -q "$janet_src"
        git -C "$janet_src" remote add origin https://github.com/janet-lang/janet.git
        git -C "$janet_src" fetch -q --depth 1 origin "{{ janet_commit }}"
        git -C "$janet_src" checkout -q FETCH_HEAD
        # Nix's compiler wrapper fortifies what it compiles, and Janet builds
        # its bootstrap with -O0, which glibc warns about once per file. The
        # bootstrap only writes janet.c, so build it without fortification.
        # The wrapper reads its hardening from NIX_HARDENING_ENABLE, which
        # nothing outside Nix reads.
        hardening=" ${NIX_HARDENING_ENABLE-} "
        hardening=${hardening// fortify3 / }
        hardening=${hardening// fortify / }
        NIX_HARDENING_ENABLE=$hardening \
            make -s -C "$janet_src" -j"$(getconf _NPROCESSORS_ONLN)" build/c/janet.c build/janet.h
    fi
    # The image in herd.c is marshaled by the Janet jpm runs on, and unmarshaled
    # by the janet.c built from the pin. Another release may expect other core
    # functions or another bytecode, so the two have to agree.
    host_version=$(jpm --local janet -e '(print janet/version)')
    pinned_version=$(sed -n 's/^#define JANET_VERSION "\(.*\)"$/\1/p' \
                     "$janet_src/src/conf/janetconf.h")
    if [[ "$host_version" != "$pinned_version" ]]; then
        echo "build/herd.c was made by Janet $host_version, but janet_commit" \
             "is Janet ${pinned_version:-of unknown version}." >&2
        echo "Make the dev shell's Janet and janet_commit name the same release." >&2
        exit 1
    fi
    # jpm keeps the cache of every spork commit it has fetched, so take the
    # one project.janet pins.
    spork_commit=$(sed -n 's/.*:tag "\([0-9a-f]*\)".*/\1/p' project.janet)
    spork="jpm_tree/lib/.cache/git_${spork_commit}_https___github.com_janet-lang_spork.git"
    if [[ -z "$spork_commit" || ! -d "$spork" ]]; then
        echo "jpm_tree holds no spork source for the commit project.janet" \
             "pins (${spork_commit:-none found})." >&2
        exit 1
    fi
    # Each native module the image registers, as jpm names its static entry.
    # A module loaded as a .so exports janet_module_entry, but linked into one
    # binary they would clash, so each is compiled with JANET_ENTRY_NAME set to
    # a name of its own. jpm makes it from the module name: it prefixes
    # janet_module_entry_ and writes any byte that is not a letter, digit or _
    # as _<decimal code>_, so spork/crc, with / being 47, becomes
    # janet_module_entry_spork_47_crc. build/herd.c calls it by that name.
    modules=(
        "src/access.c janet_module_entry_access"
        "src/terminal.c janet_module_entry_terminal"
        "$spork/src/crc.c janet_module_entry_spork_47_crc"
        "$spork/src/json.c janet_module_entry_spork_47_json"
        "$spork/src/rawterm.c janet_module_entry_spork_47_rawterm"
    )
    # A module the image registers and this list lacks would fail to link,
    # but one it lacks and the list keeps would link silently, so compare
    # both ways.
    expected=$(grep -o 'janet_module_entry_[a-z0-9_]*(temptab)' build/herd.c \
               | sed 's/(temptab)//' | sort)
    listed=$(printf '%s\n' "${modules[@]}" | cut -d' ' -f2 | sort)
    if [[ "$expected" != "$listed" ]]; then
        echo "build/herd.c registers modules the module list does not match:" >&2
        diff <(echo "$expected") <(echo "$listed") >&2 || true
        exit 1
    fi
    for platform in "${platforms[@]}"; do
        target=$(target_of "$platform")
        objects="$out/$platform/obj"
        mkdir -p "$objects"
        cc=(zig cc -target "$target" -O2 -I"$janet_src/build")
        for module in "${modules[@]}"; do
            read -r source entry <<<"$module"
            "${cc[@]}" -c "$source" -DJANET_ENTRY_NAME="$entry" \
                -o "$objects/$(basename "$source" .c).o"
        done
        "${cc[@]}" -s -o "$out/$platform/herd" build/herd.c \
            "$janet_src/build/c/janet.c" "$objects"/*.o -lm -lpthread
        echo "$out/$platform/herd: $(file -b "$out/$platform/herd")"
    done

# Install the release binary for the host platform, as just dist builds it.
install:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ os() }}-{{ arch() }}" in
        linux-x86_64) platform=linux-x86_64 ;;
        linux-aarch64) platform=linux-aarch64 ;;
        macos-aarch64) platform=macos-arm64 ;;
        macos-x86_64) platform=macos-x86_64 ;;
        *)
            echo "No release binary for {{ os() }}-{{ arch() }}" >&2
            exit 1
            ;;
    esac
    just dist "$platform"
    mkdir -p "$HOME/.local/bin"
    install -m 755 "dist/$platform/herd" "$HOME/.local/bin/herd"
    echo "Installed dist/$platform/herd as $HOME/.local/bin/herd"

# Update the flake inputs and show the resulting dev shell package changes.
flake-update-diff:
    #!/usr/bin/env bash
    set -euo pipefail
    system=$(nix eval --impure --raw --expr builtins.currentSystem)
    target=".#devShells.${system}.default"
    # Build the dev shell closure before and after updating, then diff the two.
    before=$(nix build --no-link --no-warn-dirty --print-out-paths "$target")
    # Three --quiet flags drop nix below warn level, hiding the "updating
    # lock file" notice; errors still print and still abort the recipe.
    nix flake update --no-warn-dirty --quiet --quiet --quiet
    after=$(nix build --no-link --no-warn-dirty --print-out-paths "$target")
    nix shell nixpkgs#nvd --command nvd diff "$before" "$after"

# Remove build artifacts and the local JPM trees.
clean:
    rm -rf build dist jpm_tree
