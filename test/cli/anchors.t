Where a list's repositories resolve: its anchors, the rows that read it,
and what happens when two entries name the same checkout.

  $ . "$TESTDIR/setup.sh"
  $ cd "$HOME"
  $ cat >"$CONFIG/repos.json" <<'EOF'
  > [{"path": "relative", "ssh_url": "relative-url"},
  >  {"path": "/absolute", "ssh_url": "absolute-url"}]
  > EOF

A relative path joins the anchor, and an absolute one is used as written.

  $ echo '{:checkouts [{:from "repos.json" :anchor "root"}]}' >"$CONFIG/config.jdn"
  $ herd list -a -C /
  $ROOT/home/root/relative\trelative-url (esc)
  /absolute\tabsolute-url (esc)

Several rows check the relative tree out at each anchor, while an absolute
path stays one repository reachable from all of them.

  $ echo '{:checkouts [{:from "repos.json" :anchor "one"} {:from "repos.json" :anchor "two"}]}' \
  >   >"$CONFIG/config.jdn"
  $ herd list -a -C /
  $ROOT/home/one/relative\trelative-url (esc)
  /absolute\tabsolute-url (esc)
  $ROOT/home/two/relative\trelative-url (esc)
  $ herd list -C one
  $ROOT/home/one/relative\trelative-url (esc)
  $ herd list -C two
  $ROOT/home/two/relative\trelative-url (esc)

An absolute anchor need not exist.

  $ echo '{:checkouts [{:from "repos.json" :anchor "/missing/anchor"}]}' >"$CONFIG/config.jdn"
  $ herd list -C /missing/anchor
  /missing/anchor/relative\trelative-url (esc)

Each row strips its own number of components.

  $ echo '[{"path": "org/team/repo", "ssh_url": "url"}]' >"$CONFIG/repos.json"
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:checkouts [{:from "repos.json" :anchor "one" :strip-components 1}
  >              {:from "repos.json" :anchor "two" :strip-components 2}]}
  > EOF
  $ herd list -a -C /
  $ROOT/home/one/team/repo\turl (esc)
  $ROOT/home/two/repo\turl (esc)

A list no row reads is checked out once, from the defaults alone.

  $ echo '[{"path": "one", "ssh_url": "one-url"}]' >"$CONFIG/first.json"
  $ echo '[{"path": "two", "ssh_url": "two-url"}]' >"$CONFIG/repos.json"
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:defaults {:anchor "root"}
  >  :checkouts [{:from "repos.json" :anchor "elsewhere"}]}
  > EOF
  $ herd list -a -C /
  $ROOT/home/root/one\tone-url (esc)
  $ROOT/home/elsewhere/two\ttwo-url (esc)

A row reading a list that is gone fails, even once no list is left at all.

  $ echo '{:checkouts [{:from "renamed.json"}]}' >"$CONFIG/config.jdn"
  $ herd list
  Configuration error: config.jdn: :checkouts reads "renamed.json", which is not in the configuration directory
  [1]
  $ rm "$CONFIG"/*.json
  $ herd list
  Configuration error: config.jdn: :checkouts reads "renamed.json", which is not in the configuration directory
  [1]

An empty settings file with no lists is simply nothing configured.

  $ echo '{}' >"$CONFIG/config.jdn"
  $ herd list
  No configuration files in $ROOT/home/.config/herd
  $ rm "$CONFIG/config.jdn"

A list linked into the configuration directory is anchored where it is
seen, not where it lives.

  $ mkdir elsewhere
  $ echo '[{"path": "gamma", "ssh_url": "gamma-url"}]' >elsewhere/b.json
  $ ln -s "$HOME/elsewhere/b.json" "$CONFIG/link.json"
  $ herd list -a -C /
  $ROOT/home/gamma\tgamma-url (esc)

Without HOME, the configuration directory is the default anchor, and a
relative anchor cannot be resolved.

  $ env -u HOME "$HERD" list -a -C / | sed "s|$ROOT|\$ROOT|g"
  $ROOT/home/.config/herd/gamma\tgamma-url (esc)
  $ echo '{:checkouts [{:from "link.json" :anchor "work"}]}' >"$CONFIG/config.jdn"
  $ env -u HOME "$HERD" list -a -C / 2>&1 | sed "s|$ROOT|\$ROOT|g"
  Configuration error: $ROOT/home/.config/herd/link.json: cannot resolve relative anchor for link.json without HOME
  $ rm "$CONFIG/config.jdn" "$CONFIG/link.json"

Two lists may name one checkout while they agree on its URL and how it is
checked out, and are refused when they do not. src/alpha carries no vcs of
its own, so it is a jj checkout.

  $ echo '[{"path": "src/alpha", "ssh_url": "alpha"}]' >"$CONFIG/a.json"
  $ echo '[{"path": "src/alpha", "ssh_url": "alpha"}]' >"$CONFIG/agrees.json"
  $ herd list
  $ROOT/home/src/alpha\talpha (esc)
  $ echo '[{"path": "src/alpha", "ssh_url": "different"}]' >"$CONFIG/agrees.json"
  $ herd list
  Configuration error: $ROOT/home/.config/herd/a.json and $ROOT/home/.config/herd/agrees.json disagree on the URL for $ROOT/home/src/alpha
  [1]
  $ echo '[{"path": "src/alpha", "ssh_url": "alpha", "vcs": "git"}]' >"$CONFIG/agrees.json"
  $ herd list
  Configuration error: $ROOT/home/.config/herd/a.json and $ROOT/home/.config/herd/agrees.json disagree on the vcs for $ROOT/home/src/alpha
  [1]
  $ echo '[{"path": "src/alpha", "ssh_url": "alpha", "vcs": "jj"}]' >"$CONFIG/agrees.json"
  $ herd list
  $ROOT/home/src/alpha\talpha (esc)
  $ rm "$CONFIG"/*.json

Paths that stripping makes equal are merged the same way.

  $ echo '[{"path": "one/repo", "ssh_url": "shared"}, {"path": "two/repo", "ssh_url": "shared"}]' \
  >   >"$CONFIG/repos.json"
  $ echo '{:checkouts [{:from "repos.json" :anchor "root" :strip-components 1}]}' >"$CONFIG/config.jdn"
  $ herd list -C root
  $ROOT/home/root/repo\tshared (esc)
  $ echo '[{"path": "one/repo", "ssh_url": "first"}, {"path": "two/repo", "ssh_url": "second"}]' \
  >   >"$CONFIG/repos.json"
  $ herd list -C root
  Configuration error: $ROOT/home/.config/herd/repos.json and $ROOT/home/.config/herd/repos.json disagree on the URL for $ROOT/home/root/repo
  [1]
