Filters select repositories by what their entries say, through jp.

  $ command -v jp > /dev/null || exit 80
  $ . "$TESTDIR/setup.sh"
  $ two_repos
  $ cd "$HOME"

  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:filters {"platform" "[?group=='platform']"
  >            "none" "[?group=='none']"}}
  > EOF

  $ herd list -f platform
  $ROOT/home/src/api\t$ROOT/origins/api (esc)

Filters narrow one after the other.

  $ herd list -f platform -f none
  No configured repository is left by .* (re)

  $ herd list -f nope
  Unknown filter "nope"; configured filters are "none", "platform"
  [1]

A row's :filter applies to its own list.

  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:filters {"platform" "[?group=='platform']"}
  >  :checkouts [{:from "repos.json" :filter ["platform"]}]}
  > EOF
  $ herd list
  $ROOT/home/src/api\t$ROOT/origins/api (esc)
  $ herd clone -j 1
  Clone complete: $ROOT/home/src/api
  1 cloned, 0 already checked out, 0 failed

A filter has to select an array; an expression that is not a filter
answers null, which is refused rather than read as selecting nothing.

  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:filters {"bare" "path" "broken" "[?" "group" "[?starts_with(group, 'p')]"}}
  > EOF
  $ herd list -f bare
  Configuration error: $ROOT/home/.config/herd/repos.json: filter "bare" did not select an array of repositories
  [1]

A filter jp rejects is named, with what jp said.

  $ herd list -f broken
  Configuration error: $ROOT/home/.config/herd/repos.json: filter "broken" failed: SyntaxError: Incomplete expression
  [?
    ^
  a filter named with -f is applied to every configured list, and a field a list does not carry reads as null, which most JMESPath functions reject rather than treat as no match; naming it as `field || ''` gives them a string to work with
  [1]

A filter named with -f is applied to every list, including ones it was not
written for, and says so when it fails there.

  $ echo '[{"path": "src/docs", "ssh_url": "docs"}]' >"$CONFIG/more.json"
  $ herd list -f group
  Configuration error: $ROOT/home/.config/herd/more.json: filter "group" failed: Error evaluating JMESPath expression: Invalid type for: <nil>, expected: []jmespath.jpType{"string"}
  a filter named with -f is applied to every configured list, and a field a list does not carry reads as null, which most JMESPath functions reject rather than treat as no match; naming it as `field || ''` gives them a string to work with
  [1]
  $ rm "$CONFIG/more.json"

Without jp, a filter cannot run, and says what it needs. Naming no filter
needs no jp.

  $ mkdir nojp
  $ env PATH="$ROOT/nojp" "$HERD" list -f bare 2>&1 | sed "s|$ROOT|\$ROOT|g"
  Configuration error: $ROOT/home/.config/herd/repos.json: filter "bare" needs jp on PATH
  $ env PATH="$ROOT/nojp" "$HERD" list 2>&1 | sed "s|$ROOT|\$ROOT|g"
  $ROOT/home/src/api\t$ROOT/origins/api (esc)
  $ROOT/home/src/web\t$ROOT/origins/web (esc)

Filters run as a pipeline, in the order named: the first of the active
repositories is not the first repository kept if it is active.

  $ cat >"$CONFIG/repos.json" <<EOF
  > [{"path": "one", "ssh_url": "u", "active": false, "tier": 1},
  >  {"path": "two", "ssh_url": "u", "active": true, "tier": 1}]
  > EOF
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:filters {"active" "[?active]" "tier" "[?tier == `1`]" "first" "[0:1]"}}
  > EOF
  $ herd list -f active -f tier
  $ROOT/home/two\tu (esc)
  $ herd list -f tier -f active
  $ROOT/home/two\tu (esc)
  $ herd list -f active -f first
  $ROOT/home/two\tu (esc)
  $ herd list -f first -f active
  No configured repository is left by filters "first" and "active"

A list may carry entries that are not repositories, as long as a row's
filter removes them; unfiltered, they are errors.

  $ cat >"$CONFIG/repos.json" <<'EOF'
  > [{"path": "a", "ssh_url": "a-url", "group": "src"},
  >  {"path": "org/b", "ssh_url": "b-url", "group": "vendor"},
  >  {"note": "not a repository at all"}]
  > EOF
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:filters {"src" "[?group=='src']" "vendor" "[?group=='vendor']"}
  >  :checkouts [{:from "repos.json" :anchor "src" :filter ["src"]}
  >              {:from "repos.json" :anchor "vendor" :filter ["vendor"]
  >               :strip-components 1}]}
  > EOF
  $ herd list -a -C /
  $ROOT/home/src/a\ta-url (esc)
  $ROOT/home/vendor/b\tb-url (esc)
  $ herd list -a -C / -f vendor
  $ROOT/home/vendor/b\tb-url (esc)
  $ echo '{:checkouts [{:from "repos.json"}]}' >"$CONFIG/config.jdn"
  $ herd list -a -C /
  Configuration error: $ROOT/home/.config/herd/repos.json: entry 2 needs a string "path"
  [1]
