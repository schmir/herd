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

  $ herd run -C src/api --show-output always sh -c 'echo "$HERD_REPO_JSON"' | grep -o '"members":\[[^]]*\]'
  "members":[{"user":"bob"}]
  $ herd run -C src/web --show-output always sh -c 'echo "$HERD_REPO_JSON"' | grep -o '"clone_url":"[^"]*"' | sed "s|$ROOT|\$ROOT|"
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
