A command is told the fields of the repository list entry it runs for.

  $ . "$TESTDIR/setup.sh"
  $ origin api
  $ origin web
  $ cat >"$CONFIG/repos.json" <<EOF
  > [{"path": "src/api", "ssh_url": "$ROOT/origins/api", "vcs": "git",
  >   "group": "platform", "approvals": 2, "archived": false,
  >   "owner": {"name": "ann", "team": {"id": 7}},
  >   "members": [{"user": "bob"}], "a-b": 1, "a_b": 2},
  >  {"path": "src/web", "ssh_url": "$ROOT/origins/web", "vcs": "git"}]
  > EOF
  $ cd "$HOME"
  $ herd clone -j 1
  Clone complete: $ROOT/home/src/api
  Clone complete: $ROOT/home/src/web
  2 cloned, 0 already checked out, 0 blocked, 0 failed

Each string, number and boolean is a variable. A nested key adds its name
after two underscores. Arrays and objects give none themselves, and neither
do the fields that HERD_REPO_URL and its kin already tell.

  $ herd run -C src/api --show-output always sh -c 'env | grep ^HERD_FIELD_ | sort'
  \xe2\x9c\x93 $ROOT/home/src/api (esc)
  | HERD_FIELD_APPROVALS=2
  | HERD_FIELD_ARCHIVED=false
  | HERD_FIELD_GROUP=platform
  | HERD_FIELD_OWNER__NAME=ann
  | HERD_FIELD_OWNER__TEAM__ID=7
  1 succeeded, 0 failed, 0 skipped, 0 not checked out

A repository without the field has no such variable, and one that herd
inherited does not describe another repository.

  $ HERD_FIELD_GROUP=stale herd run -C src/web --show-output always sh -c 'echo "[$HERD_FIELD_GROUP]"'
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | []
  1 succeeded, 0 failed, 0 skipped, 0 not checked out

HERD_REPO_JSON holds the whole entry, the fields that have no variable too.

  $ herd run -C src/api --show-output always sh -c 'printf "%s\n" "$HERD_REPO_JSON"' | grep -o '"members":\[[^]]*\]'
  "members":[{"user":"bob"}]
  $ herd run -C src/web --show-output always sh -c 'printf "%s\n" "$HERD_REPO_JSON"' | grep -o '"clone_url":"[^"]*"' | sed "s|$ROOT|\$ROOT|"
  "clone_url":"$ROOT/origins/web"

A custom command can branch on a field.

  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:commands {"which" {:description "Show the group."
  >            :command "echo $HERD_REPO_RELPATH is $HERD_FIELD_GROUP"}}}
  > EOF
  $ herd which -j 1 --show-output always
  \xe2\x9c\x93 $ROOT/home/src/api (esc)
  | src/api is platform
  
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | src/web is
  2 succeeded, 0 failed, 0 skipped, 0 not checked out

A field gives no variable when its name clashes with another or has nothing
left, when it is null, or when its string holds a NUL. HERD_REPO_JSON still
holds it.

  $ cat >"$CONFIG/repos.json" <<'EOF'
  > [{"path": "src/api", "ssh_url": "unused", "vcs": "git",
  >   "empty": null, "a-b": 1, "a_b": 2, "!!!": "ignored", "nul": "a\u0000b"}]
  > EOF
  $ herd run -C src/api --show-output always sh -c 'env | grep ^HERD_FIELD_ | sort'
  1 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ herd run -C src/api --show-output always sh -c 'printf "%s\n" "$HERD_REPO_JSON"' \
  >   | grep -o -e '"empty":null' -e '"a-b":1' -e '"a_b":2' -e '"!!!":"ignored"' -e '"nul":"a\\u0000b"' | sort
  "!!!":"ignored"
  "a-b":1
  "a_b":2
  "empty":null
  "nul":"a\u0000b"

A field named "null", at any depth, is a key in HERD_REPO_JSON, not a JSON
null.

  $ cat >"$CONFIG/repos.json" <<'EOF'
  > [{"path": "src/api", "ssh_url": "unused", "vcs": "git",
  >   "null": 1, "owner": {"null": 2}}]
  > EOF
  $ herd run -C src/api --show-output always sh -c 'printf "%s\n" "$HERD_REPO_JSON"' \
  >   | grep -o -e '"null":1' -e '"owner":{"null":2}' | sort
  "null":1
  "owner":{"null":2}

An entry that holds a number too large for a double cannot be written as
HERD_REPO_JSON. The command for that repository fails and says so, the
command for the others still runs, and herd exits with status 1.

  $ cat >"$CONFIG/repos.json" <<EOF
  > [{"path": "src/api", "ssh_url": "$ROOT/origins/api", "vcs": "git", "n": 1e400},
  >  {"path": "src/web", "ssh_url": "$ROOT/origins/web", "vcs": "git"}]
  > EOF
  $ herd run -j 1 --show-output always echo ran
  \xe2\x9c\x97 $ROOT/home/src/api (esc)
  ! HERD_REPO_JSON cannot be written: encode error: numbers must be finite
  
  \xe2\x9c\x93 $ROOT/home/src/web (esc)
  | ran
  1 succeeded, 1 failed, 0 skipped, 0 not checked out
  [1]
