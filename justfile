set shell := ["bash", "-euo", "pipefail", "-c"]

# Show the available project commands.
default:
    @just --list

# Install project dependencies in the local JPM tree.
deps:
    jpm --local deps

# Run the program
run *args: deps
    jpm --local janet main.janet {{ args }}

# Build the standalone executable in build/.
build *args: deps
    HERD_VERSION="${HERD_VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}" \
        jpm --local build {{ args }}

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
    version="${HERD_VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
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

# Remove build artifacts and the local JPM trees.
clean:
    rm -rf build build-musl jpm_tree
