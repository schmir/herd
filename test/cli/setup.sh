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
unset HERD_CONFIG
CONFIG="$XDG_CONFIG_HOME/herd"
mkdir -p "$CONFIG" "$ROOT/bin"

# Invoked as plain `herd`, which is also what its usage line then shows.
ln -s "$HERD" "$ROOT/bin/herd"
PATH="$ROOT/bin:$PATH"

# Git and jj take much of their behaviour from the environment, which can also
# override what a configuration file says, and a Git hook runs with GIT_DIR
# set. Clear all of their own variables, and the general ones they consult.
for name in $(env | sed -n -E 's/^((GIT|JJ)_[A-Za-z0-9_]*)=.*/\1/p'); do
    unset "$name"
done
unset EDITOR VISUAL PAGER EMAIL SSH_ASKPASS NO_COLOR XDG_CACHE_HOME
unset RUST_LOG RUST_BACKTRACE

# Keep the user's Git and jj configuration out, and give commits an author
# from files of the test's own.
cat >"$ROOT/.gitconfig" <<EOF
[user]
	name = test
	email = test@example.com
EOF
cat >"$ROOT/.jjconfig.toml" <<EOF
[user]
name = "test"
email = "test@example.com"
EOF
export GIT_CONFIG_GLOBAL="$ROOT/.gitconfig" GIT_CONFIG_NOSYSTEM=1
export JJ_CONFIG="$ROOT/.jjconfig.toml"

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
# one per line, in $ROOT/$1.args, and makes its last argument a Git
# repository, as a clone would, and succeeds.
fake() {
    cat >"$ROOT/bin/$1" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >"$ROOT/$1.args"
for dest; do :; done
mkdir -p "\$dest/.git"
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
