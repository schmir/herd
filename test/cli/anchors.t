Where a list's repositories resolve: its anchors, the rows that read it,
and what happens when two entries name the same checkout.

  $ . "$TESTDIR/setup.sh"
  $ cd "$HOME"
  $ cat >"$CONFIG/repos.json" <<'EOF'
  > [{"path": "relative", "ssh_url": "relative-url"}]
  > EOF

A path joins the anchor.

  $ echo '{:checkouts [{:list "repos.json" :anchor "root"}]}' >"$CONFIG/config.jdn"
  $ herd list -a -C /
  missing\t$ROOT/home/root/relative\trelative-url (esc)

Several rows check the tree out at each anchor.

  $ echo '{:checkouts [{:list "repos.json" :anchor "one"} {:list "repos.json" :anchor "two"}]}' \
  >   >"$CONFIG/config.jdn"
  $ herd list -a -C /
  missing\t$ROOT/home/one/relative\trelative-url (esc)
  missing\t$ROOT/home/two/relative\trelative-url (esc)
  $ herd list -C one
  missing\t$ROOT/home/one/relative\trelative-url (esc)
  $ herd list -C two
  missing\t$ROOT/home/two/relative\trelative-url (esc)

A path may not climb out of its anchor, and may not be absolute: every
repository lies beneath the anchor of the row that places it.

  $ echo '[{"path": "../sibling", "ssh_url": "url"}]' >"$CONFIG/repos.json"
  $ echo '{:checkouts [{:list "repos.json" :anchor "root"}]}' >"$CONFIG/config.jdn"
  $ herd list -a -C /
  Configuration error: $ROOT/home/.config/herd/repos.json: entry 0 has a "path" that leaves its anchor
  [1]
  $ echo '[{"path": "a/../../sibling", "ssh_url": "url"}]' >"$CONFIG/repos.json"
  $ herd list -a -C /
  Configuration error: $ROOT/home/.config/herd/repos.json: entry 0 has a "path" that leaves its anchor
  [1]
  $ echo '[{"path": "/srv/abs", "ssh_url": "url"}]' >"$CONFIG/repos.json"
  $ herd list -a -C /
  Configuration error: $ROOT/home/.config/herd/repos.json: entry 0 has an absolute "path"; write it relative to its anchor
  [1]
  $ echo '[{"path": "relative", "ssh_url": "relative-url"}]' >"$CONFIG/repos.json"

An absolute anchor need not exist.

  $ echo '{:checkouts [{:list "repos.json" :anchor "/missing/anchor"}]}' >"$CONFIG/config.jdn"
  $ herd list -C /missing/anchor
  missing\t/missing/anchor/relative\trelative-url (esc)

Each row strips its own number of components.

  $ echo '[{"path": "org/team/repo", "ssh_url": "url"}]' >"$CONFIG/repos.json"
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:checkouts [{:list "repos.json" :anchor "one" :strip-components 1}
  >              {:list "repos.json" :anchor "two" :strip-components 2}]}
  > EOF
  $ herd list -a -C /
  missing\t$ROOT/home/one/team/repo\turl (esc)
  missing\t$ROOT/home/two/repo\turl (esc)

A list no row reads is checked out once, from the defaults alone.

  $ echo '[{"path": "one", "ssh_url": "one-url"}]' >"$CONFIG/first.json"
  $ echo '[{"path": "two", "ssh_url": "two-url"}]' >"$CONFIG/repos.json"
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:checkout-defaults {:anchor "root"}
  >  :checkouts [{:list "repos.json" :anchor "elsewhere"}]}
  > EOF
  $ herd list -a -C /
  missing\t$ROOT/home/root/one\tone-url (esc)
  missing\t$ROOT/home/elsewhere/two\ttwo-url (esc)

A row reading a list that is gone fails, even once no list is left at all.

  $ echo '{:checkouts [{:list "renamed.json"}]}' >"$CONFIG/config.jdn"
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
  No repository lists in $ROOT/home/.config/herd
  $ rm "$CONFIG/config.jdn"

A list linked into the configuration directory is anchored where it is
seen, not where it lives.

  $ mkdir elsewhere
  $ echo '[{"path": "gamma", "ssh_url": "gamma-url"}]' >elsewhere/b.json
  $ ln -s "$HOME/elsewhere/b.json" "$CONFIG/link.json"
  $ herd list -a -C /
  missing\t$ROOT/home/gamma\tgamma-url (esc)

Without HOME there is no default anchor, and a relative anchor cannot be
resolved either.

  $ env -u HOME "$HERD" list -a -C / 2>&1 | sed "s|$ROOT|\$ROOT|g"
  Configuration error: $ROOT/home/.config/herd/link.json: cannot place link.json without HOME
  $ echo '{:checkouts [{:list "link.json" :anchor "work"}]}' >"$CONFIG/config.jdn"
  $ env -u HOME "$HERD" list -a -C / 2>&1 | sed "s|$ROOT|\$ROOT|g"
  Configuration error: $ROOT/home/.config/herd/link.json: cannot resolve relative anchor for link.json without HOME
  $ echo '{:checkouts [{:list "link.json" :anchor "/abs"}]}' >"$CONFIG/config.jdn"
  $ env -u HOME "$HERD" list -a -C / 2>&1 | sed "s|$ROOT|\$ROOT|g"
  missing\t/abs/gamma\tgamma-url (esc)

The default anchor is $HOME unless :checkout-defaults sets it. Setting it to false
leaves a list that no row anchors without any anchor, which is an error,
while a row that names an anchor still places its list.

  $ echo '[{"path": "delta", "ssh_url": "delta-url"}]' >"$CONFIG/other.json"
  $ echo '{:checkout-defaults {:anchor "src"}}' >"$CONFIG/config.jdn"
  $ herd list -a -C /
  missing\t$ROOT/home/src/gamma\tgamma-url (esc)
  missing\t$ROOT/home/src/delta\tdelta-url (esc)
  $ echo '{:checkout-defaults {:anchor false}}' >"$CONFIG/config.jdn"
  $ herd list -a -C /
  Configuration error: $ROOT/home/.config/herd/link.json: cannot place link.json: the default anchor is disabled
  [1]
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:checkout-defaults {:anchor false}
  >  :checkouts [{:list "link.json" :anchor "one"} {:list "other.json" :anchor "two"}]}
  > EOF
  $ herd list -a -C /
  missing\t$ROOT/home/one/gamma\tgamma-url (esc)
  missing\t$ROOT/home/two/delta\tdelta-url (esc)
  $ cat >"$CONFIG/config.jdn" <<'EOF'
  > {:checkout-defaults {:anchor false}
  >  :checkouts [{:list "link.json"} {:list "other.json" :anchor "two"}]}
  > EOF
  $ herd list -a -C /
  Configuration error: $ROOT/home/.config/herd/link.json: cannot place link.json: the default anchor is disabled
  [1]
  $ echo '{:checkout-defaults {:anchor false} :checkouts [{:list "other.json" :anchor false}]}' \
  >   >"$CONFIG/config.jdn"
  $ herd list
  Configuration error: $ROOT/home/.config/herd/config.jdn: :checkouts row 0 needs a non-empty :anchor
  [1]
  $ rm "$CONFIG/config.jdn" "$CONFIG/link.json" "$CONFIG/other.json"

Two lists may name one checkout while they agree on its URL and how it is
checked out, and are refused when they do not. src/alpha carries no vcs of
its own, so it is a git checkout.

  $ echo '[{"path": "src/alpha", "ssh_url": "alpha"}]' >"$CONFIG/a.json"
  $ echo '[{"path": "src/alpha", "ssh_url": "alpha"}]' >"$CONFIG/agrees.json"
  $ herd list
  missing\t$ROOT/home/src/alpha\talpha (esc)
  $ echo '[{"path": "src/alpha", "ssh_url": "different"}]' >"$CONFIG/agrees.json"
  $ herd list
  Configuration error: $ROOT/home/.config/herd/a.json and $ROOT/home/.config/herd/agrees.json disagree on the URL for $ROOT/home/src/alpha
  [1]
  $ echo '[{"path": "src/alpha", "ssh_url": "alpha", "vcs": "jj"}]' >"$CONFIG/agrees.json"
  $ herd list
  Configuration error: $ROOT/home/.config/herd/a.json and $ROOT/home/.config/herd/agrees.json disagree on the vcs for $ROOT/home/src/alpha
  [1]
  $ echo '[{"path": "src/alpha", "ssh_url": "alpha", "vcs": "git"}]' >"$CONFIG/agrees.json"
  $ herd list
  missing\t$ROOT/home/src/alpha\talpha (esc)
  $ rm "$CONFIG"/*.json

Paths that stripping makes equal are merged the same way.

  $ echo '[{"path": "one/repo", "ssh_url": "shared"}, {"path": "two/repo", "ssh_url": "shared"}]' \
  >   >"$CONFIG/repos.json"
  $ echo '{:checkouts [{:list "repos.json" :anchor "root" :strip-components 1}]}' >"$CONFIG/config.jdn"
  $ herd list -C root
  missing\t$ROOT/home/root/repo\tshared (esc)
  $ echo '[{"path": "one/repo", "ssh_url": "first"}, {"path": "two/repo", "ssh_url": "second"}]' \
  >   >"$CONFIG/repos.json"
  $ herd list -C root
  Configuration error: $ROOT/home/.config/herd/repos.json and $ROOT/home/.config/herd/repos.json disagree on the URL for $ROOT/home/root/repo
  [1]

A repository may not live inside another one, whichever anchor or list
places it there.

  $ echo '[{"path": "outer", "ssh_url": "o"}, {"path": "outer/inner", "ssh_url": "i"}]' \
  >   >"$CONFIG/repos.json"
  $ echo '{:checkouts [{:list "repos.json" :anchor "root"}]}' >"$CONFIG/config.jdn"
  $ herd list -a -C /
  Configuration error: $ROOT/home/.config/herd/repos.json names $ROOT/home/root/outer/inner, which lies inside the repository $ROOT/home/root/outer from $ROOT/home/.config/herd/repos.json
  [1]
  $ echo '[{"path": "outer", "ssh_url": "o"}, {"path": "outer-two/x", "ssh_url": "i"}]' \
  >   >"$CONFIG/repos.json"
  $ herd list -a -C /
  missing\t$ROOT/home/root/outer\to (esc)
  missing\t$ROOT/home/root/outer-two/x\ti (esc)

A command is told the first anchor of a repository that several rows reach
(an anchor may sit above another), and its path as the list gives it once
stripped.

  $ mkdir -p abs/.git three/repo/.git
  $ rm "$CONFIG/repos.json"
  $ echo '[{"path": "abs", "ssh_url": "abs-url"}]' >"$CONFIG/abs.json"
  $ echo "[{\"path\": \"home/abs\", \"ssh_url\": \"abs-url\"}]" >"$CONFIG/up.json"
  $ echo '[{"path": "org/repo", "ssh_url": "repo-url"}]' >"$CONFIG/rel.json"
  $ cat >"$CONFIG/config.jdn" <<EOF
  > {:checkouts [{:list "abs.json" :anchor "$HOME"}
  >              {:list "up.json" :anchor "$ROOT"}
  >              {:list "rel.json" :anchor "three" :strip-components 1}]}
  > EOF
  $ herd run -a -C abs --show-output always sh -c 'printf "%s\n" "$HERD_REPO_ANCHOR" "$HERD_REPO_PATH"'
  \xe2\x9c\x93 $ROOT/home/abs (esc)
  | $ROOT/home
  | abs
  1 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ herd run -C three/repo --show-output always sh -c 'printf "%s\n" "$HERD_REPO_ANCHOR" "$HERD_REPO_PATH"'
  \xe2\x9c\x93 $ROOT/home/three/repo (esc)
  | $ROOT/home/three
  | repo
  1 succeeded, 0 failed, 0 skipped, 0 not checked out
