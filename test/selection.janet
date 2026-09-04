# Tests for the parts that need nothing but their arguments.
(use spork/test)
(import ../main :as herd)

(start-suite "selection")

(def repositories
  [{:path "/srv/foo" :ssh_url "git@example.com:foo.git"}
   {:path "/srv/foo/bar" :ssh_url "git@example.com:bar.git"}
   {:path "/srv/foobar" :ssh_url "git@example.com:foobar.git"}
   {:path "/srv/other" :ssh_url "git@example.com:other.git"}])

(defn- selected
  "Paths selected by `path`, so the assertions read as plain lists."
  [path]
  (map |($ :path) (herd/select-repositories path repositories)))

# A directory selects everything checked out below it.
(assert (deep= (selected "/srv/foo") @["/srv/foo" "/srv/foo/bar"]))
(assert (deep= (selected "/srv")
               @["/srv/foo" "/srv/foo/bar" "/srv/foobar" "/srv/other"]))
(assert (deep= (selected "/") (map |($ :path) repositories)))

# A path inside a working copy selects that repository, however deep.
(assert (deep= (selected "/srv/foo/deep/inside") @["/srv/foo"]))
(assert (deep= (selected "/srv/foobar/x") @["/srv/foobar"]))

# Nested repositories both hold a path below them.
(assert (deep= (selected "/srv/foo/bar/x") @["/srv/foo" "/srv/foo/bar"]))

# Matching is by whole segment, not by string prefix.
(assert (empty? (selected "/srv/fo")))
(assert (deep= (selected "/srv/foobar") @["/srv/foobar"]))

# Trailing slashes and unnormalised paths mean what they look like.
(assert (deep= (selected "/srv/foo/") (selected "/srv/foo")))
(assert (deep= (selected "/srv/foo//") (selected "/srv/foo")))
(assert (deep= (selected "/srv/foo/../foo") (selected "/srv/foo")))

# A relative path is read from the current directory.
(assert (deep= (map |($ :path)
                    (herd/select-repositories
                      "below" [{:path (string (os/cwd) "/below/repo") :ssh_url "u"}]))
               @[(string (os/cwd) "/below/repo")]))

(assert (empty? (herd/select-repositories "/srv" [])))
(assert (empty? (selected "/elsewhere")))

(end-suite)
