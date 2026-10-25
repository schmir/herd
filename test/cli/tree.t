`herd tree` draws the filesystem the configuration describes, with the
lists marked at the directories they are anchored at.

  $ . "$TESTDIR/setup.sh"
  $ cat >"$CONFIG/repos.json" <<'EOF'
  > [{"path": "acme/api", "clone_url": "api-url"},
  >  {"path": "acme/web", "clone_url": "web-url"},
  >  {"path": "x/y/z/deep", "clone_url": "deep-url"},
  >  {"path": "x/y/other", "clone_url": "other-url"},
  >  {"path": "t/top", "clone_url": "top-url"}]
  > EOF
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:jobs 3
  >  :checkouts [{:list "repos.json" :anchor "/srv/work" :vcs "git"}
  >              {:list "repos.json" :anchor "/srv/mirror" :strip-components 1}
  >              {:list [{:path "dotfiles" :clone-url "dot-url"}] :anchor "/srv/me"}]}
  > EOF
  $ herd tree -r
  /srv/me (config.jdn: :checkouts row 2, 1 repository)
  └── dotfiles
  
  /srv/mirror (repos.json [strip 1], 3 repositories)
  ├── api
  ├── top
  ├── web
  └── y/ (1 repository)
      ├── other
      └── z/ (1 repository)
          └── deep
  
  /srv/work (repos.json [vcs git])
  ├── acme/ (2 repositories)
  │   ├── api
  │   └── web
  ├── t/ (1 repository)
  │   └── top
  └── x/y/ (1 repository)
      ├── other
      └── z/ (1 repository)
          └── deep

A directory gives the number of repositories in it. -r lists them too.

  $ echo '[{"path": "m/a", "clone_url": "u"}, {"path": "m/b", "clone_url": "u"}, {"path": "m/c", "clone_url": "u"}, {"path": "m/d", "clone_url": "u"}, {"path": "n/a", "clone_url": "u"}, {"path": "n/b", "clone_url": "u"}, {"path": "n/c", "clone_url": "u"}, {"path": "n/d", "clone_url": "u"}, {"path": "n/e", "clone_url": "u"}, {"path": "n/f", "clone_url": "u"}, {"path": "n/s/g", "clone_url": "u"}]' \
  >   >"$CONFIG/many.json"
  $ echo '{:checkouts [{:list "many.json" :anchor "/srv/many"}]}' >"$CONFIG/config.jdn"
  $ rm "$CONFIG/repos.json"
  $ herd tree
  /srv/many (many.json)
  ├── m/ (4 repositories)
  └── n/ (6 repositories)
      └── s/ (1 repository)
  $ herd tree -r | tail -3
      ├── f
      └── s/ (1 repository)
          └── g

Lists placed at the same anchor are not merged: the directory is shown once
for each, with the repositories of that list.

  $ echo '[{"path": "p/one", "clone_url": "u"}]' >"$CONFIG/first.json"
  $ echo '[{"path": "q/two", "clone_url": "u"}]' >"$CONFIG/second.json"
  $ echo '{:checkouts [{:list "first.json" :anchor "/srv/shared"}
  >                    {:list "second.json" :anchor "/srv/shared"}]}' >"$CONFIG/config.jdn"
  $ rm "$CONFIG/many.json"
  $ herd tree -r
  /srv/shared (first.json)
  └── p/ (1 repository)
      └── one
  
  /srv/shared (second.json)
  └── q/ (1 repository)
      └── two

An anchor inside another is shown inside it, where it is on disk.

  $ echo '{:checkouts [{:list "first.json" :anchor "/srv/outer"}
  >                    {:list "second.json" :anchor "/srv/outer/in/ner"}]}' >"$CONFIG/config.jdn"
  $ herd tree -r
  /srv/outer (first.json)
  ├── in/ner/ (second.json)
  │   └── q/ (1 repository)
  │       └── two
  └── p/ (1 repository)
      └── one

Beside several placements at one anchor, what else is below it, such as an
anchor further down, is an entry of its own with no placement.

  $ echo '{:checkouts [{:list "first.json" :anchor "/srv/outer"}
  >                    {:list "second.json" :anchor "/srv/outer"}
  >                    {:list "second.json" :anchor "/srv/outer/in"}]}' >"$CONFIG/config.jdn"
  $ herd tree -r
  /srv/outer (first.json)
  └── p/ (1 repository)
      └── one
  
  /srv/outer (second.json)
  └── q/ (1 repository)
      └── two
  
  /srv/outer
  └── in/ (second.json)
      └── q/ (1 repository)
          └── two

A repository of the enclosing placement stays in its entry, even in a
directory where another placement is anchored.

  $ rm "$CONFIG/second.json"
  $ echo '[{"path": "in/mine", "clone_url": "u"}]' >"$CONFIG/third.json"
  $ echo '{:checkouts [{:list "third.json" :anchor "/srv/outer"}
  >                    {:list "first.json" :anchor "/srv/outer/in"}]}' >"$CONFIG/config.jdn"
  $ herd tree -r
  /srv/outer (third.json)
  ├── in/ (1 repository)
  │   └── mine
  └── in/ (first.json)
      └── p/ (1 repository)
          └── one

A repository at the anchor itself is counted, and listed as ".".

  $ rm "$CONFIG/third.json" "$CONFIG/first.json"
  $ echo '[{"path": ".", "clone_url": "u"}, {"path": "a", "clone_url": "v"}]' >"$CONFIG/self.json"
  $ echo '{:checkouts [{:list "self.json" :anchor "/srv/work"}]}' >"$CONFIG/config.jdn"
  $ herd tree
  /srv/work (self.json, 2 repositories)
  $ herd tree -r
  /srv/work (self.json, 2 repositories)
  ├── .
  └── a
