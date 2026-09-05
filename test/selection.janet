# Tests for the parts that need nothing but their arguments.
(use spork/test)
(import ../main :as herd)

(start-suite "selection")

(def repositories
  [{:path "/srv/foo" :ssh_url "git@example.com:foo.git" :anchors @["/srv"]}
   {:path "/srv/foo/bar" :ssh_url "git@example.com:bar.git" :anchors @["/srv"]}
   {:path "/srv/foobar" :ssh_url "git@example.com:foobar.git" :anchors @["/srv"]}
   {:path "/srv/other" :ssh_url "git@example.com:other.git" :anchors @["/srv"]}])

(defn- selected
  "Return selected paths so assertions read as plain lists."
  [path anchors &opt all-anchors]
  (map |($ :path)
       (herd/select-repositories-with-anchors
         path repositories all-anchors anchors)))

# A directory selects everything checked out below it.
(assert (deep= (selected "/srv/foo" @["/srv"]) @["/srv/foo" "/srv/foo/bar"]))
(assert (deep= (selected "/srv" @["/srv"])
               @["/srv/foo" "/srv/foo/bar" "/srv/foobar" "/srv/other"]))
(assert (empty? (selected "/" @[])) "no configured anchor contains the filesystem root")
(assert (deep= (selected "/" @[] true) (map |($ :path) repositories))
        "all anchors restores selection from the filesystem root")

# A path inside a working copy selects that repository, however deep.
(assert (deep= (selected "/srv/foo/deep/inside" @["/srv"]) @["/srv/foo"]))
(assert (deep= (selected "/srv/foobar/x" @["/srv"]) @["/srv/foobar"]))

# Nested repositories both hold a path below them.
(assert (deep= (selected "/srv/foo/bar/x" @["/srv"])
               @["/srv/foo" "/srv/foo/bar"]))

# Matching is by whole segment, not by string prefix.
(assert (empty? (selected "/srv/fo" @["/srv"])))
(assert (deep= (selected "/srv/foobar" @["/srv"]) @["/srv/foobar"]))

# Trailing slashes and unnormalised paths mean what they look like.
(assert (deep= (selected "/srv/foo/" @["/srv"])
               (selected "/srv/foo" @["/srv"])))
(assert (deep= (selected "/srv/foo//" @["/srv"])
               (selected "/srv/foo" @["/srv"])))
(assert (deep= (selected "/srv/foo/../foo" @["/srv"])
               (selected "/srv/foo" @["/srv"])))

# A relative path is read from the current directory.
(assert (deep= (map |($ :path)
                    (herd/select-repositories-with-anchors
                      "below" [{:path (string (os/cwd) "/below/repo")
                                :ssh_url "u"
                                :anchors @[(os/cwd)]}]
                      false @[(os/cwd)]))
               @[(string (os/cwd) "/below/repo")]))

(assert (empty? (herd/select-repositories-with-anchors "/srv" [] false @["/srv"])))
(assert (empty? (selected "/elsewhere" @[])))

(def nested
  [{:path "/work/one" :ssh_url "one" :anchors @["/work"]}
   {:path "/work/team/two" :ssh_url "two" :anchors @["/work/team"]}
   {:path "/work/team/parent" :ssh_url "parent" :anchors @["/work"]}
   {:path "/work/team/shared" :ssh_url "shared"
    :anchors @["/work" "/work/team"]}
   {:path "/work/team/unrelated" :ssh_url "unrelated" :anchors @["/other"]}])

(defn- selected-nested
  "Return paths selected from repositories with nested anchors."
  [path anchors &opt all-anchors]
  (map |($ :path)
       (herd/select-repositories-with-anchors
         path nested all-anchors anchors)))

(assert (deep= @["/work" "/work/team"]
               (herd/containing-anchors "/work/team/inside" nested))
        "all containing anchors are selected")
(assert (empty? (herd/containing-anchors "/elsewhere" nested))
        "an unrelated path has no anchor")
(assert (deep= (selected-nested "/work/team" @["/work" "/work/team"])
               @["/work/team/two" "/work/team/parent" "/work/team/shared"])
        "repositories from every containing anchor are selected")
(assert (deep= (selected-nested "/work" @["/work"])
               @["/work/one" "/work/team/parent" "/work/team/shared"])
        "a nested anchor does not contain its parent directory")
(assert (deep= (selected-nested "/work/team" @[] true)
               @["/work/team/two" "/work/team/parent" "/work/team/shared"
                 "/work/team/unrelated"])
        "all anchors also includes unrelated anchors")
(assert (deep= (selected-nested "/work/team/parent/deep" @["/work" "/work/team"])
               @["/work/team/parent"])
        "a repository from any containing anchor can hold the path")

(end-suite)
