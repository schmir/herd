# Tests for selecting repositories, mostly from arguments alone.
(use spork/test)
(import spork/path)
(import spork/sh)
(import ../location)
(import ../select)

(start-suite "selection")

(def repositories
  [{:path "/srv/foo" :ssh_url "git@example.com:foo.git" :anchors @["/srv"]}
   {:path "/srv/foo/bar" :ssh_url "git@example.com:bar.git" :anchors @["/srv"]}
   {:path "/srv/foobar" :ssh_url "git@example.com:foobar.git" :anchors @["/srv"]}
   {:path "/srv/other" :ssh_url "git@example.com:other.git" :anchors @["/srv"]}])

(defn- selected
  "Return selected paths so assertions read as plain lists."
  [path anchors &opt all-anchors]
  (map (fn [repository] (repository :path))
       (location/select-repositories-with-anchors
         path repositories all-anchors anchors)))

# A directory selects everything checked out below it.
(assert (deep= (selected "/srv/foo" @["/srv"]) @["/srv/foo" "/srv/foo/bar"]))
(assert (deep= (selected "/srv" @["/srv"])
               @["/srv/foo" "/srv/foo/bar" "/srv/foobar" "/srv/other"]))
(assert (empty? (selected "/" @[])) "no configured anchor contains the filesystem root")
(assert (deep= (selected "/" @[] true) (map (fn [repository] (repository :path)) repositories))
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
(assert (deep= (map (fn [repository] (repository :path))
                    (location/select-repositories-with-anchors
                      "below" [{:path (string (os/cwd) "/below/repo")
                                :ssh_url "u"
                                :anchors @[(os/cwd)]}]
                      false @[(os/cwd)]))
               @[(string (os/cwd) "/below/repo")]))

(assert (empty? (location/select-repositories-with-anchors "/srv" [] false @["/srv"])))
(assert (empty? (selected "/elsewhere" @[])))

(let [selected (select/by-location "/srv/foo" false repositories)]
  (assert (deep= @["/srv"] (selected :anchors))
          "the selection boundary returns containing anchors")
  (assert (deep= @["/srv/foo" "/srv/foo/bar"]
                 (map (fn [repository] (repository :path))
                      (selected :repositories)))
          "the selection boundary returns repositories below the location"))

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
  (map (fn [repository] (repository :path))
       (location/select-repositories-with-anchors
         path nested all-anchors anchors)))

(assert (deep= @["/work" "/work/team"]
               (location/containing-anchors "/work/team/inside" nested))
        "all containing anchors are selected")
(assert (empty? (location/containing-anchors "/elsewhere" nested))
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

(defn- scratch-dir
  "Create and resolve a fresh directory for one selection test."
  [name]
  (def dir (path/join (os/getenv "TMPDIR" "/tmp")
                      (string name "-" (os/getpid))))
  (sh/rm dir)
  (sh/create-dirs dir)
  (os/realpath dir))

# Configured paths and the working location may reach the same directory
# through different symlinks, so both sides are resolved before comparison.
(let [dir (scratch-dir "herd-selection-test")
      real (string dir "/real/work")
      alias (string dir "/link/work")]
  (sh/create-dirs (string real "/repo"))
  (os/link (string dir "/real") (string dir "/link") true)
  (defn- linked
    "Return the paths selected for a working location and one repository."
    [at repository-path anchor]
    (def repositories [{:path repository-path :ssh_url "u"
                        :anchors @[anchor]}])
    (map (fn [repository] (repository :path))
         (location/select-repositories-with-anchors
           at repositories false (location/containing-anchors at repositories))))

  (assert (deep= (linked real (string alias "/repo") alias) @[(string alias "/repo")])
          "a working location selects a repository configured through a link")
  (assert (deep= (linked alias (string real "/repo") real) @[(string real "/repo")])
          "a working location reached through a link selects a repository")
  (assert (deep= (linked real (string alias "/absent") alias)
                 @[(string alias "/absent")])
          "a repository that is not checked out yet is still selected")
  (assert (empty? (linked real (string alias "/repo") (string dir "/other")))
          "resolving does not make an unrelated anchor contain the location")
  (sh/rm dir))

(defn- git-selection
  "Run Git for the by-state fixture with isolated commit identity."
  [directory & args]
  (def env (merge (os/environ)
                  @{"GIT_CONFIG_GLOBAL" "/dev/null"
                    "GIT_AUTHOR_NAME" "test" "GIT_AUTHOR_EMAIL" "t@example.com"
                    "GIT_COMMITTER_NAME" "test" "GIT_COMMITTER_EMAIL" "t@example.com"}))
  (assert (zero? (os/execute ["git" "-C" directory ;args] :pe env))
          (string "git " (string/join args " ") " succeeds")))

(let [scratch (scratch-dir "herd-selection-state-test")
      root (path/join scratch "root")
      first (string root "/first")
      second (string root "/second")]
  (var stages 0)
  (sh/create-dirs first)
  (sh/create-dirs second)
  (git-selection first "init" "-q")
  (git-selection first "commit" "-q" "--allow-empty" "-m" "init")
  (git-selection second "init" "-q")
  (git-selection second "commit" "-q" "--allow-empty" "-m" "init")
  (spit (string first "/marker") "")
  (def kept
    (select/by-state [{:path first} {:path second}]
                     :dirty ["test -f marker"] 1
                     (fn [] (++ stages))))
  (assert (deep= @[first] (map (fn [repository] (repository :path)) kept))
          "by-state keeps repositories that pass every shell command")
  (assert (= 2 stages)
          "by-state reports each completed selection stage")
  (def both [{:path first} {:path second}])
  (def paths (fn [repositories] (map (fn [r] (r :path)) repositories)))
  (set stages 0)
  (assert (deep= @[second] (paths (select/by-state both :clean [] 1
                                                   (fn [] (++ stages)))))
          "a state alone keeps the repositories in that state")
  (assert (= 1 stages) "a state alone is one stage")
  (set stages 0)
  (assert (deep= @[first] (paths (select/by-state both nil ["test -f marker"] 1
                                                  (fn [] (++ stages)))))
          "commands alone keep the repositories where they succeed")
  (assert (= 1 stages) "commands alone are one stage")
  (assert (deep= @[first second] (paths (select/by-state both nil [] 1)))
          "no state and no commands keeps everything")
  (assert (deep= @[first] (paths (select/by-state both nil ["test -f marker"] 1)))
          "the after-stage callback is optional")
  (sh/rm scratch))

(end-suite)
