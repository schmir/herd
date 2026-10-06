# Sourced by every test. HERD names the binary under test, so the same tests
# run against build/herd and against a release binary.
#
# Each test gets a home and a configuration directory of its own, and
# clones from local Git repositories, so nothing reads the real
# configuration or reaches the network.

# Without HERD, test the build in this tree, so a plain prysk run works.
: "${HERD:=$(cd "$TESTDIR/../.." && pwd -P)/build/herd}"

if [ ! -x "${HERD:-}" ]; then
    echo "HERD must name the herd binary to test" >&2
    exit 1
fi

# Name the binary once per run, on the terminal, since prysk compares
# everything a test prints.
if [ ! -e "$PRYSK_TEMP/herd-shown" ]; then
    : >"$PRYSK_TEMP/herd-shown"
    { echo "testing $HERD" >/dev/tty; } 2>/dev/null
fi

# The physical path, since macOS reaches the temp directory through a
# symlink and herd prints the paths it resolves.
ROOT=$(pwd -P)
export HOME="$ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
CONFIG="$XDG_CONFIG_HOME/herd"
mkdir -p "$CONFIG" "$ROOT/bin"

# Invoked as plain `herd`, which is also what its usage line then shows.
ln -s "$HERD" "$ROOT/bin/herd"
PATH="$ROOT/bin:$PATH"

# Keep the user's Git configuration out, and give commits an author.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

# Run herd with $ROOT in place of the temp directory, which differs on every
# run, keeping its exit status.
herd() {
    command herd "$@" >"$ROOT/.herd-out" 2>&1
    set -- $?
    sed "s|$ROOT|\$ROOT|g" "$ROOT/.herd-out"
    return "$1"
}

# Create a Git repository with one commit under $ROOT/origins, to clone from.
origin() {
    git init -q -b main "$ROOT/origins/$1"
    git -C "$ROOT/origins/$1" commit -q --allow-empty -m init
}

# Put a stand-in for the program $1 ahead of PATH that records its arguments,
# one per line, in $ROOT/$1.args and succeeds without doing anything else.
fake() {
    cat >"$ROOT/bin/$1" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >"$ROOT/$1.args"
EOF
    chmod +x "$ROOT/bin/$1"
}

# Configure the repositories src/api and src/web, cloned with Git from
# local origins.
two_repos() {
    origin api
    origin web
    cat >"$CONFIG/repos.json" <<EOF
[{"path": "src/api", "ssh_url": "$ROOT/origins/api", "vcs": "git",
  "group": "platform"},
 {"path": "src/web", "ssh_url": "$ROOT/origins/web", "vcs": "git"}]
EOF
}
