set shell := ["bash", "-euo", "pipefail", "-c"]

# Show the available project commands.
default:
    @just --list

# Install project dependencies in the local JPM tree.
deps:
    jpm --local deps

# Run the program, optionally with a configuration path.
run *args: deps
    jpm --local janet main.janet {{args}}

# Build the standalone executable in build/.
build *args: deps
    jpm --local build {{args}}

# Remove build artifacts and the local JPM tree.
clean:
    rm -rf build jpm_tree
