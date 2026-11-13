set shell := ["bash", "-euo", "pipefail", "-c"]

# Export the build version so all recipes that invoke jpm use the same value.
export HERD_VERSION := env_var_or_default("HERD_VERSION", `git describe --tags --always --dirty 2>/dev/null || echo dev`)

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

# Build the standalone executable in build/. It is the host half of just dist:
# ninja runs jpm, and rebuilds when a source file, pins.jdn or HERD_VERSION
# changes.
build:
    janet tools/gen-ninja.janet
    ninja host

# Run the test suite in test/.
test: deps
    jpm --local test

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
    HERD="$herd" uv run prysk test/cli/

# herd runs commands with `sh -c`, found on PATH, and the message a shell
# gives for an unknown command differs from one shell to the next. Put each
# shell ahead of PATH as `sh` and run the command-line tests under it:
# dash (Debian, Ubuntu), bash (macOS, Fedora), busybox ash (Alpine) and mksh,
# which stands in for OpenBSD's ksh. The devshell provides them. The first
# run uses the system's own /bin/sh: bash 3.2 on macOS, usually dash on Linux.
[doc('Run the command-line tests with each of several shells as sh.')]
test-cli-shells herd="":
    #!/usr/bin/env bash
    set -euo pipefail
    herd="{{ herd }}"
    if [[ -z "$herd" ]]; then
        just build
        herd=build/herd
    fi
    [[ "$herd" == /* ]] || herd="$PWD/$herd"
    bin=$(mktemp -d)
    trap 'rm -rf "$bin"' EXIT
    failed=()
    for shell in /bin/sh dash bash busybox mksh; do
        if ! target=$(command -v "$shell"); then
            echo "skipping $shell: not found" >&2
            continue
        fi
        rm -f "$bin/sh"
        ln -s "$target" "$bin/sh"
        echo "== sh is $shell ($target)" >&2
        if ! PATH="$bin:$PATH" HERD="$herd" uv run prysk test/cli/; then
            failed+=("$shell")
        fi
    done
    if (( ${#failed[@]} )); then
        echo "failed with: ${failed[*]}" >&2
        exit 1
    fi

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

# The platforms are linux-x86_64, linux-aarch64, macos-arm64, macos-x86_64,
# openbsd-arm64, openbsd-amd64, freebsd-arm64 and freebsd-amd64.
#
# jpm's own build runs src/main.janet with the host janet and writes the
# marshaled image into build/herd.c. That step has to run here, since it loads
# native modules, but what it writes is portable C. Only the final compile needs
# the target, and that is plain C: herd.c, the amalgamated janet.c, and every
# native module the image registers, built in statically.
#
# tools/gen-ninja.janet writes the build.ninja that runs these steps, reading
# the Janet and spork commits in pins.jdn. ninja compiles the platforms in
# parallel and only what changed.
[doc('Cross-compile release binaries with zig cc, for the platforms named or all of them.')]
dist *platforms:
    janet tools/gen-ninja.janet
    ninja {{ platforms }}

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
    rm -rf build dist jpm_tree build.ninja .ninja_log .ninja_deps src/*.egg-info .venv
