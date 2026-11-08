Without jp a placement whose filters need it is broken. Only a command that
has to read the placement fails, and `herd tree` shows it as broken.

  $ . "$TESTDIR/setup.sh"
  $ mkdir nojp
  $ cat >"$CONFIG/repos.json" <<'JSON'
  > [{"path": "api", "clone_url": "api-url", "group": "platform"},
  >  {"path": "web", "clone_url": "web-url"}]
  > JSON
  $ cat >"$CONFIG/config.jdn" <<'JDN'
  > {:filters {"platform" "[?group=='platform']"}
  >  :checkouts [{:list "repos.json" :anchor "/srv/all"}
  >              {:list "repos.json" :anchor "/srv/platform" :use-filters ["platform"]}]}
  > JDN

A location outside the broken placement is not affected.

  $ env PATH="$ROOT/nojp" "$HERD" list -C /srv/all
  missing\t/srv/all/api\tapi-url (esc)
  missing\t/srv/all/web\tweb-url (esc)

A location inside it, or one that considers every anchor, has to read it.

  $ env PATH="$ROOT/nojp" "$HERD" list -C /srv/platform 2>&1 | sed "s|$ROOT|\$ROOT|g"
  Configuration error: $ROOT/home/.config/herd/repos.json: filter "platform" needs jp on PATH
  $ env PATH="$ROOT/nojp" "$HERD" list -a -C /srv 2>&1 | sed "s|$ROOT|\$ROOT|g"
  Configuration error: $ROOT/home/.config/herd/repos.json: filter "platform" needs jp on PATH
  $ env PATH="$ROOT/nojp" "$HERD" list -a -C /srv/all 2>&1 | sed "s|$ROOT|\$ROOT|g"
  missing\t/srv/all/api\tapi-url (esc)
  missing\t/srv/all/web\tweb-url (esc)

A selection of only the extra repositories reads no placement, so it works
even inside the broken one.

  $ env PATH="$ROOT/nojp" "$HERD" list --extra -C /srv/platform
  $ env PATH="$ROOT/nojp" "$HERD" list --extra -a -C /srv

The tree shows the placement that cannot be read.

  $ env PATH="$ROOT/nojp" "$HERD" tree -r
  /srv/all (repos.json, 2 repositories)
  ├── api
  └── web
  
  /srv/platform (repos.json [filters platform; broken: needs jp])

A list may not name an absolute path, or one outside its anchor.

  $ echo '[{"path": "/srv/x", "clone_url": "u"}]' >"$CONFIG/repos.json"
  $ "$HERD" list -a -C / 2>&1 | sed "s|$ROOT|\$ROOT|g"
  Configuration error: $ROOT/home/.config/herd/repos.json: entry 0 has an absolute "path"; write it relative to its anchor
