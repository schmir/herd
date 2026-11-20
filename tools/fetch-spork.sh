#!/usr/bin/env bash
# Check out a spork commit into a directory. Usage: fetch-spork.sh DIR COMMIT
#
# DIR.commit records the commit DIR holds, for ninja. When DIR already holds
# COMMIT, the tracked files that are missing or changed are restored. git
# leaves the others alone, so ninja sees nothing change. Otherwise DIR is
# removed first: ninja makes the directories of the outputs before this runs,
# and a directory without a checkout must not stop it.
set -euo pipefail
dir=$1
commit=$2
stamp="$dir.commit"

if [[ -d "$dir/.git" &&
    "$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null)" == "$commit" ]]; then
    git -C "$dir" checkout -q -f HEAD -- .
else
    rm -rf "$dir"
    git init -q "$dir"
    git -C "$dir" fetch -q --depth 1 https://github.com/janet-lang/spork.git "$commit"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
fi
if [[ "$(cat "$stamp" 2>/dev/null)" != "$commit" ]]; then
    printf '%s\n' "$commit" >"$stamp"
fi
