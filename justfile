set shell := ["bash", "-euo", "pipefail", "-c"]

# Export the build version so all recipes that invoke jpm use the same value.
export HERD_VERSION := env_var_or_default("HERD_VERSION", `git describe --tags --always --dirty 2>/dev/null || echo dev`)

# Janet 1.41.2. The release binaries are cross-compiled from it, and the
# container tests build it, so this is the one place it is pinned.
janet_commit := "0fea20c82182fe661f75b00a8889d801fe2d79b6"

# Show the available project commands.
default:
    @just --list

# Install the locked dependencies in the local JPM tree.
deps: check-lock
    jpm --local load-lockfile

# Nothing else notices the drift: load-lockfile never reads project.janet, and
# a missing dependency only surfaces as a failing import much later.
[doc('Fail when project.janet declares a dependency lockfile.jdn does not record.')]
check-lock:
    #!/usr/bin/env janet
    (def declared
      (mapcat |(get (struct ;(slice $ 1)) :dependencies [])
              (filter |(and (tuple? $) (= 'declare-project (first $)))
                      (parse-all (slurp "project.janet")))))
    (def locked (map |(get $ :url) (parse (slurp "lockfile.jdn"))))
    (def missing (filter |(nil? (index-of $ locked)) declared))
    (unless (empty? missing)
      (eprint "lockfile.jdn does not record: " (string/join missing ", "))
      (eprint "Run `just lock` to regenerate it.")
      (os/exit 1))

# Regenerate lockfile.jdn from the dependencies declared in project.janet.
lock:
    #!/usr/bin/env bash
    set -euo pipefail
    # Resolve into a throwaway tree: make-lockfile records whatever the tree
    # happens to contain, so anything installed into jpm_tree by hand would
    # otherwise end up in the lockfile too.
    tree="$(mktemp -d)"
    trap 'rm -rf "$tree"' EXIT
    jpm --tree="$tree" deps
    jpm --tree="$tree" make-lockfile lockfile.jdn
    treefmt lockfile.jdn

# Janet looks for a native module by bare name on the module path, and jpm
# adds build/ to it only for the builds and test runs it drives itself. These
# two recipes run the interpreter directly, so they say where to look, and
# they build first so there is something there to find.
native_path := '(array/insert module/paths 1 ["build/:all:.so" :native])'

# Run the program.
run *args: build
    jpm --local janet -e '{{ native_path }}' -- main.janet {{ args }}

# Start a REPL inside a source file, private bindings included.
repl file="main.janet": build
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

# Run the test suite in the Podman test container.
test-podman:
    podman build --build-arg JANET_COMMIT={{ janet_commit }} --tag herd-test .
    podman run --rm herd-test

# Run the test suite in Podman test containers for amd64 and arm64.
test-podman-multi:
    #!/usr/bin/env bash
    set -euo pipefail
    platforms=linux/amd64,linux/arm64
    manifest=localhost/herd-test-multi
    # --manifest amends an existing manifest. Remove it so each run tests only
    # freshly built images.
    podman manifest rm -i "$manifest"
    podman build --build-arg JANET_COMMIT={{ janet_commit }} \
        --platform "$platforms" --manifest "$manifest" .
    for platform in ${platforms//,/ }; do
        echo "==> $platform"
        # Prevent Podman from searching registries for a platform image that
        # exists only in the local manifest.
        podman run --rm --pull=never --platform "$platform" "$manifest"
    done

# Format the tree and run the test suite.
ci: && test
    treefmt

# The platforms are linux-x86_64, linux-aarch64, macos-arm64 and macos-x86_64.
#
# jpm's own build runs main.janet with the host janet and writes the marshaled
# image into build/herd.c. That step has to run here, since it loads native
# modules, but what it writes is portable C. Only the final compile needs the
# target, and that is plain C: herd.c, the amalgamated janet.c, and every
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
    # one the lockfile pins.
    spork_commit=$(sed -n 's/.*spork\.git" :tag "\([0-9a-f]*\)".*/\1/p' lockfile.jdn)
    spork="jpm_tree/lib/.cache/git_${spork_commit}_https___github.com_janet-lang_spork.git"
    if [[ -z "$spork_commit" || ! -d "$spork" ]]; then
        echo "jpm_tree holds no spork source for the commit lockfile.jdn" \
             "pins (${spork_commit:-none found})." >&2
        exit 1
    fi
    # Each native module the image registers, as jpm names its static entry.
    modules=(
        "access.c janet_module_entry_access"
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
