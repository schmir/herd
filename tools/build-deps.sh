#!/usr/bin/env bash
# Fetch the JPM dependencies into jpm_tree. Usage: build-deps.sh CHECKOUT_DIR
#
# CHECKOUT_DIR is where jpm keeps its checkout of spork, which ninja lists as
# the output of this step. ninja makes the directories of an output before it
# runs a step, so when jpm_tree is missing there is an empty CHECKOUT_DIR and
# CHECKOUT_DIR/src here. jpm takes a directory that exists for a checkout and
# runs git fetch in it. An empty directory is no repository, so git goes on to
# the enclosing one, which is this project's, and fails with "not our ref".
# Remove what ninja made first. rmdir only removes empty directories, so a real
# checkout stays, and so does anything half-written in one.
set -euo pipefail
checkout=${1:?usage: build-deps.sh CHECKOUT_DIR}

rmdir "$checkout/src" "$checkout" 2>/dev/null || true
exec jpm --local deps
