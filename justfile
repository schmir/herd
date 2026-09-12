set shell := ["bash", "-euo", "pipefail", "-c"]

# Export the build version so all recipes that invoke jpm use the same value.
export HERD_VERSION := env_var_or_default("HERD_VERSION", `git describe --tags --always --dirty 2>/dev/null || echo dev`)

# Show the available project commands.
default:
    @just --list

# Install project dependencies in the local JPM tree.
deps:
    jpm --local deps

# Run the program
run *args: deps
    jpm --local janet main.janet {{ args }}

# Start a REPL inside a source file, private bindings included.
repl file="main.janet": deps
    jpm --local janet -e '(repl nil nil (dofile "{{ file }}"))'

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

# Format the tree and run the test suite.
ci: && test
    treefmt

# Build musl based static Linux binary with podman
build-musl:
    #!/usr/bin/env bash
    set -euo pipefail
    version="$HERD_VERSION"
    podman build \
        --build-arg HERD_VERSION="$version" \
        --output type=local,dest=build-musl .
    # Bold green, but only when a terminal is watching, so redirected output
    # stays free of escape codes.
    bold="" reset=""
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then bold=$'\033[1;32m' reset=$'\033[0m'; fi
    echo
    echo "${bold}Static binary: build-musl/herd ($version, $(du -h build-musl/herd | cut -f1))${reset}"

# Build and install the executable for the host platform.
install:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ os() }}" in
        linux)
            just install-musl
            ;;
        macos)
            just build
            install -D -m 755 build/herd "$HOME/.local/bin/herd"
            ;;
        *)
            echo "Unsupported platform: {{ os() }}" >&2
            exit 1
            ;;
    esac

# Install the static Linux binary in the user executable directory.
install-musl: build-musl
    install -D -m 755 build-musl/herd "$HOME/.local/bin/herd"

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
    rm -rf build build-musl jpm_tree
