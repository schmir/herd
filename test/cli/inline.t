A :checkouts row may hold its repositories inline, as an array in :list,
instead of naming a file.

  $ . "$TESTDIR/setup.sh"
  $ cd "$HOME"

With no repository list files at all, an inline list is still configured.

  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:checkouts [{:list [{:path "dotfiles" :clone-url "dotfiles-url"}
  >                     {:path "notes" :clone-url "notes-url" :vcs "git"}]
  >               :anchor "personal"}]}
  > EOF
  $ herd list -a -C /
  $ROOT/home/personal/dotfiles\tdotfiles-url (esc)
  $ROOT/home/personal/notes\tnotes-url (esc)

The row's anchor, strip count and defaults apply as they do to a file.

  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:checkout-defaults {:anchor "src"}
  >  :checkouts [{:list [{:path "org/team/repo" :clone-url "repo-url"}]
  >               :strip-components 2}
  >              {:list [{:path "abs" :clone-url "abs-url"}] :anchor "/srv/inline"}]}
  > EOF
  $ herd list -a -C /
  $ROOT/home/src/repo\trepo-url (esc)
  /srv/inline/abs\tabs-url (esc)

Inline lists join the files, and agree with them or are refused like any
two lists naming one checkout.

  $ echo '[{"path": "repo", "clone_url": "repo-url"}]' >"$CONFIG/repos.json"
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:checkouts [{:list "repos.json" :anchor "files"}
  >              {:list [{:path "inline" :clone-url "inline-url"}] :anchor "files"}]}
  > EOF
  $ herd list -a -C /
  $ROOT/home/files/repo\trepo-url (esc)
  $ROOT/home/files/inline\tinline-url (esc)
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:checkouts [{:list "repos.json" :anchor "files"}
  >              {:list [{:path "repo" :clone-url "other-url"}] :anchor "files"}]}
  > EOF
  $ herd list -a -C /
  Configuration error: $ROOT/home/.config/herd/repos.json and config.jdn: :checkouts row 1 disagree on the URL for $ROOT/home/files/repo
  [1]
  $ rm "$CONFIG/repos.json"

Entries are checked like those of a file, and the error names the row.

  $ echo '{:checkouts [{:list [{:path "x"}]}]}' >"$CONFIG/config.jdn"
  $ herd list
  Configuration error: config.jdn: :checkouts row 0: entry 0 needs a string "clone_url"
  [1]
  $ echo '{:checkouts [{:list [{:path "x" :ssh_url "u"}]}]}' >"$CONFIG/config.jdn"
  $ herd list
  Configuration error: config.jdn: :checkouts row 0: entry 0 needs :clone-url, not :ssh_url
  [1]
  $ echo '{:checkouts [{:list ["x"]}]}' >"$CONFIG/config.jdn"
  $ herd list
  Configuration error: config.jdn: :checkouts row 0: entry 0 is not a dictionary
  [1]

An empty inline list is a list with no repositories.

  $ echo '{:checkouts [{:list []}]}' >"$CONFIG/config.jdn"
  $ herd list -a -C /

Filters see an inline list as the JSON a file would hold, with the URL
under clone_url.

  $ command -v jp > /dev/null || exit 80
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:filters {"platform" "[?group=='platform']"}
  >  :checkouts [{:list [{:path "api" :clone-url "api-url" :group "platform"}
  >                     {:path "web" :clone-url "web-url" :group "other"}]
  >               :anchor "work" :filter ["platform"]}]}
  > EOF
  $ herd list -a -C /
  $ROOT/home/work/api\tapi-url (esc)
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:filters {"has-url" "[?clone_url=='web-url']"}
  >  :checkouts [{:list [{:path "api" :clone-url "api-url"}
  >                     {:path "web" :clone-url "web-url"}]
  >               :anchor "work" :filter ["has-url"]}]}
  > EOF
  $ herd list -a -C /
  $ROOT/home/work/web\tweb-url (esc)
