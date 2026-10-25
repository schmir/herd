`herd tree` reads each row through the filters it names, so only the
repositories the filter keeps are drawn. Filters need jp.

  $ command -v jp > /dev/null || exit 80
  $ . "$TESTDIR/setup.sh"
  $ cat >"$CONFIG/repos.json" <<'JSON'
  > [{"path": "api", "clone_url": "api-url", "group": "platform"},
  >  {"path": "web", "clone_url": "web-url"}]
  > JSON
  $ cat >"$CONFIG/config.jdn" <<'JDN'
  > {:filters {"platform" "[?group=='platform']"}
  >  :checkouts [{:list "repos.json" :anchor "/srv/all"}
  >              {:list "repos.json" :anchor "/srv/platform" :use-filters ["platform"]}]}
  > JDN
  $ herd tree -r
  /srv/all (repos.json, 2 repositories)
  ├── api
  └── web
  
  /srv/platform (repos.json [filters platform], 1 repository)
  └── api
