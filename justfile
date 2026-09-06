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

# Remove build artifacts and the local JPM tree.
clean:
    rm -rf build jpm_tree
