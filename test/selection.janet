# Tests for selecting repositories, mostly from arguments alone.
(use spork/test)
(import spork/path)
(import spork/sh)
(import ../location)
(import ../config)
(import ../selection)

(start-suite "selection")

(def repositories
  [{:path "/srv/foo" :ssh_url "git@example.com:foo.git" :anchors @["/srv"]}
   {:path "/srv/foo/bar" :ssh_url "git@example.com:bar.git" :anchors @["/srv"]}
   {:path "/srv/foobar" :ssh_url "git@example.com:foobar.git" :anchors @["/srv"]}
   {:path "/srv/other" :ssh_url "git@example.com:other.git" :anchors @["/srv"]}])

(defn- selected
  "Return selected paths so assertions read as plain lists."
  [at-path selected-anchors]
  (map (fn [repository] (repository :path))
       (location/select-repositories-with-anchors
         at-path repositories selected-anchors)))

# A directory selects everything checked out below it.
(assert (deep= (selected "/srv/foo" @["/srv"]) @["/srv/foo" "/srv/foo/bar"]))
(assert (deep= (selected "/srv" @["/srv"])
               @["/srv/foo" "/srv/foo/bar" "/srv/foobar" "/srv/other"]))
(assert (empty? (selected "/" @[])) "no configured anchor contains the filesystem root")
(assert (deep= (selected "/" (location/configured-anchors repositories)) (map (fn [repository] (repository :path)) repositories))
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
                      @[(os/cwd)]))
               @[(string (os/cwd) "/below/repo")]))

(assert (empty? (location/select-repositories-with-anchors "/srv" [] @["/srv"])))
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
  [at-path selected-anchors]
  (map (fn [repository] (repository :path))
       (location/select-repositories-with-anchors
         at-path nested selected-anchors)))

(assert (deep= @["/work" "/work/team"]
               (location/containing-anchors "/work/team/inside" nested))
        "all containing anchors are selected")
(assert (deep= @["/work" "/work/team" "/other"] (location/configured-anchors nested))
        "configured anchors are listed once each in first-seen order")
(assert (empty? (location/containing-anchors "/elsewhere" nested))
        "an unrelated path has no anchor")
(assert (deep= (selected-nested "/work/team" @["/work" "/work/team"])
               @["/work/team/two" "/work/team/parent" "/work/team/shared"])
        "repositories from every containing anchor are selected")
(assert (deep= (selected-nested "/work" @["/work"])
               @["/work/one" "/work/team/parent" "/work/team/shared"])
        "a nested anchor does not contain its parent directory")
(assert (deep= (selected-nested "/work/team" (location/configured-anchors nested))
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
    [at-path repository-path anchor]
    (def repositories [{:path repository-path :ssh_url "u"
                        :anchors @[anchor]}])
    (map (fn [repository] (repository :path))
         (location/select-repositories-with-anchors
           at-path repositories
           (location/containing-anchors at-path repositories))))

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

# Many repositories share a few anchors, and an anchor may be spelled through a
# link in some of them and not in others. Each spelling stands for one anchor,
# and every repository under it is found whichever spelling it was given.
(let [dir (scratch-dir "herd-selection-shared-test")
      real (string dir "/real/work")
      alias (string dir "/link/work")]
  (sh/create-dirs real)
  (os/link (string dir "/real") (string dir "/link") true)
  (def shared
    (seq [i :range [0 500]]
      (def spelled (if (even? i) real alias))
      {:path (string spelled "/team" (% i 5) "/repo" i)
       :ssh_url "u"
       :anchors @[spelled]}))
  (assert (deep= @[real] (location/configured-anchors shared))
          "two spellings of one anchor are listed once")
  (assert (deep= @[real] (location/containing-anchors alias shared))
          "and either spelling of the working location finds it")
  (def everything
    (location/select-repositories-with-anchors
      real shared (location/containing-anchors real shared)))
  (assert (= 500 (length everything))
          "every repository under the anchor is selected, whichever spelling it has")
  (def team
    (location/select-repositories-with-anchors
      (string alias "/team3") shared (location/containing-anchors alias shared)))
  (assert (= 100 (length team))
          "a subdirectory selects those beneath it, through either spelling")
  (assert (empty? (location/select-repositories-with-anchors
                    (string dir "/real/elsewhere") shared
                    (location/containing-anchors (string dir "/real/elsewhere") shared)))
          "a location outside the anchor selects none")
  (sh/rm dir))

# The selection module takes what the command line asked for and says which
# repositories that picks, and why when it picks none.

(def config-dir (path/join (os/getenv "TMPDIR" "/tmp")
                           (string "herd-selection-test-" (os/getpid))))
(sh/rm config-dir)
(sh/create-dirs config-dir)
(spit (path/join config-dir "repos.json")
      (string "[{\"path\": \"/srv/foo\", \"ssh_url\": \"foo\"},"
              " {\"path\": \"/srv/foo/bar\", \"ssh_url\": \"bar\"},"
              " {\"path\": \"/srv/other\", \"ssh_url\": \"other\"}]"))

(def srv-settings
  (config/configured-repository-settings
    {:checkouts [{:from "repos.json" :anchor "/srv"}]}))

(defn- chosen
  "The paths of what selecting with `options` picks, in order."
  [options &opt settings]
  (def result (selection/select (merge {:directory config-dir} options)
                                (or settings srv-settings)))
  (map (fn [repository] (repository :path)) (result :repositories)))

(defn test-selects-beneath-the-working-location
  "A working location picks the configured repositories beneath it."
  []
  (def result (selection/select {:directory config-dir :at-path "/srv/foo"}
                                srv-settings))
  (assert (deep= @["/srv/foo" "/srv/foo/bar"]
                 (map (fn [repository] (repository :path))
                      (result :repositories))))
  (assert (nil? (result :reason)) "a selection that is not empty needs no reason"))

(test-selects-beneath-the-working-location)

(defn test-all-anchors-ignore-the-working-location-anchor
  "Considering every anchor reaches a location no anchor contains."
  []
  (assert (empty? (chosen {:at-path "/"})) "no anchor contains the filesystem root")
  (assert (deep= @["/srv/foo" "/srv/foo/bar" "/srv/other"]
                 (chosen {:at-path "/" :all-anchors? true}))
          "every anchor is considered"))

(test-all-anchors-ignore-the-working-location-anchor)

(defn- reason-of
  "The reason selecting with `options` picks nothing, or nil."
  [options &opt settings]
  ((selection/select (merge {:directory config-dir} options)
                     (or settings srv-settings)) :reason))

(defn test-reason-for-an-empty-location
  "An empty selection says whether the anchors or the location are to blame."
  []
  (assert (deep= {:kind :no-anchor-contains-path :at-path "/"}
                 (reason-of {:at-path "/"}))
          "standing outside every anchor")
  (assert (deep= {:kind :none-beneath-path :at-path "/srv/fo"}
                 (reason-of {:at-path "/srv/fo"}))
          "standing where no repository is")
  (assert (nil? (reason-of {:at-path "/srv"})) "a selection needs no reason"))

(test-reason-for-an-empty-location)

(def filter-settings
  (config/configured-repository-settings
    {:checkouts [{:from "repos.json" :anchor "/srv"}]
     :filters {"foo" "[?ssh_url=='foo']" "none" "[?ssh_url=='nothing']"}}))

(def empty-dir (path/join config-dir "empty"))
(sh/create-dirs empty-dir)
(spit (path/join empty-dir "empty.json") "[]")

(defn test-list-filters-narrow-the-catalog
  "A list filter named with -f narrows the repositories before location."
  []
  (assert (deep= @["/srv/foo"]
                 (chosen {:at-path "/srv" :filter-values ["foo"]} filter-settings))
          "the filter keeps what it matches")
  (assert (deep= {:kind :emptied-by-filters :names @["none"]}
                 (reason-of {:at-path "/srv" :filter-values ["none"]} filter-settings))
          "a filter that removes everything is named")
  (assert (deep= {:kind :emptied-by-filters :names @[]}
                 (reason-of {:at-path "/srv"}
                            (config/configured-repository-settings
                              {:checkouts [{:from "repos.json" :anchor "/srv"
                                            :filter ["none"]}]
                               :filters {"none" "[?ssh_url=='nothing']"}})))
          "a checkout row's filter is blamed when no name was given")
  (assert (deep= {:kind :empty-catalog}
                 (reason-of {:at-path "/srv" :directory empty-dir}
                            config/default-repository-settings))
          "nothing configured, nothing filtered"))

(test-list-filters-narrow-the-catalog)

(defn test-nothing-configured
  "A directory without configuration files is a state, not a failure."
  []
  (def bare-dir (path/join config-dir "bare"))
  (sh/create-dirs bare-dir)
  (def result (selection/select {:at-path "/srv" :directory bare-dir}
                                config/default-repository-settings))
  (assert (deep= {:kind :unconfigured :directory bare-dir} (result :reason)))
  (assert (empty? (result :repositories)))
  (assert (empty? ((result :catalog) :paths)) "the catalog is still there to read"))

(defn test-no-configuration-directory
  "Without XDG_CONFIG_HOME and HOME there is nowhere to look."
  []
  (def xdg (os/getenv "XDG_CONFIG_HOME"))
  (def home (os/getenv "HOME"))
  (os/setenv "XDG_CONFIG_HOME" nil)
  (os/setenv "HOME" nil)
  (def result (selection/select {:at-path "/srv"} config/default-repository-settings))
  (os/setenv "XDG_CONFIG_HOME" xdg)
  (os/setenv "HOME" home)
  (assert (deep= {:kind :no-config-directory} (result :reason)))
  (assert (empty? (result :repositories))))

(def mixed-settings
  (config/configured-repository-settings
    {:checkouts [{:from "repos.json" :anchor "/srv"}]
     :filters {"foo" "[?ssh_url=='foo']" "marked" {:sh "test -f marker"}}}))

(defn test-filter-values-are-classified
  "-f takes a list filter, a checkout filter's name, or a command, in order."
  []
  (def result
    (selection/select {:directory config-dir :at-path "/srv"
                       :filter-values ["foo" "marked" "test -d ." "foo"]}
                      mixed-settings))
  (assert (deep= {:names @["foo" "foo"]
                  :commands @["test -f marker" "test -d ."]
                  :command-values @["marked" "test -d ."]}
                 (result :filters))
          "names narrow the lists, and what runs in checkouts follows them")
  (assert (deep= @["/srv/foo"]
                 (map (fn [r] (r :path)) ((result :catalog) :repositories)))
          "only the list filters narrow what is loaded"))

(defn test-mistyped-filter
  "A single word that is neither a filter nor a program is most likely a typo."
  []
  (def result
    (selection/select {:directory config-dir :at-path "/srv"
                       :filter-values ["fooo"]}
                      mixed-settings))
  (assert (deep= {:kind :mistyped-filter :value "fooo"
                  :known @["foo" "marked"]}
                 (result :reason)))
  (assert (empty? (result :repositories)))
  (assert (nil? (result :catalog)) "nothing is loaded for a mistake in the arguments")
  (assert (not= :mistyped-filter
                (get-in (selection/select {:directory config-dir :at-path "/srv"
                                           :filter-values ["true"]}
                                          mixed-settings)
                        [:reason :kind]))
          "a word naming a program is a command"))

(test-filter-values-are-classified)
(test-mistyped-filter)
(def work-dir (path/join config-dir "work"))
(sh/create-dirs work-dir)

(defn- git
  "Run git in `directory`, failing the test when it fails."
  [directory & args]
  (def env (merge (os/environ)
                  @{"GIT_CONFIG_GLOBAL" "/dev/null"
                    "GIT_AUTHOR_NAME" "test" "GIT_AUTHOR_EMAIL" "t@example.com"
                    "GIT_COMMITTER_NAME" "test" "GIT_COMMITTER_EMAIL" "t@example.com"}))
  (assert (zero? (os/execute ["git" "-C" directory ;args] :pe env))
          (string "git " (string/join args " ") " succeeds")))

(defn- make-checkout
  "Create a Git repository with one commit under the work directory."
  [name]
  (def checkout (path/join work-dir name))
  (sh/create-dirs checkout)
  (git checkout "init" "-q")
  (git checkout "commit" "-q" "--allow-empty" "-m" "init")
  checkout)

(def work-config-dir (path/join config-dir "work-config"))
(sh/create-dirs work-config-dir)
(make-checkout "clean")
(spit (path/join (make-checkout "dirty") "marker") "")
(spit (path/join work-config-dir "work.json")
      (string "[{\"path\": \"clean\", \"ssh_url\": \"c\", \"vcs\": \"git\"},"
              " {\"path\": \"dirty\", \"ssh_url\": \"d\", \"vcs\": \"git\"}]"))

(def work-settings
  (config/configured-repository-settings
    {:checkouts [{:from "work.json" :anchor work-dir}]}))

(defn- work-select
  "Select in the work repositories with `options`."
  [options]
  (selection/select (merge {:directory work-config-dir :at-path work-dir :jobs 1}
                           options)
                    work-settings))

(defn- work-paths
  "The names of the work repositories a selection picked."
  [result]
  (map (fn [repository] (path/basename (repository :path)))
       (result :repositories)))

(defn test-state-and-commands-narrow-the-selection
  "The state and the checkout filters keep what they match, one stage after another."
  []
  (assert (deep= @["clean" "dirty"] (work-paths (work-select {}))))
  (assert (deep= @["dirty"] (work-paths (work-select {:wanted-state :dirty}))))
  (assert (deep= @["clean"] (work-paths (work-select {:wanted-state :clean}))))
  (assert (deep= @["dirty"]
                 (work-paths (work-select {:filter-values ["test -f marker"]}))))
  (assert (empty? (work-paths (work-select {:wanted-state :clean
                                            :filter-values ["test -f marker"]})))
          "the stages combine")
  (assert (deep= {:kind :emptied-by-state :of 2 :wanted :clean :commands? true}
                 ((work-select {:wanted-state :clean
                                :filter-values ["test -f marker"]}) :reason))
          "what the stages emptied is named")
  (assert (deep= {:kind :emptied-by-state :of 2 :wanted nil :commands? true}
                 ((work-select {:filter-values ["false"]}) :reason))
          "a command that matches nowhere is named")
  (def nowhere (path/join work-dir "nowhere"))
  (assert (deep= {:kind :none-beneath-path :at-path nowhere}
                 ((work-select {:at-path nowhere :wanted-state :dirty}) :reason))
          "nothing was left for the stages to empty"))

(defn test-an-interrupt-stops-the-selection
  "An interrupt during a stage ends the selection, and the result says so."
  []
  # The filter sends the interrupt to this process, which the stage has taken
  # the signal for, and still succeeds.
  (def interrupt (string "kill -INT " (os/getpid)))
  (def result (work-select {:filter-values [interrupt]}))
  (assert (result :interrupted?) "an interrupted selection says it was")
  (assert (empty? (result :repositories))
          "and picks nothing, since it did not reach them all")
  (assert (nil? (result :reason)) "which is not a reason to explain")
  (assert (not ((work-select {:filter-values ["true"]}) :interrupted?))
          "a selection nobody interrupted says so"))

(defn test-unreadable-repository-stops-the-selection
  "A failing stage raises something a caller can tell from a bad configuration."
  []
  (def broken (make-checkout "broken"))
  (spit (path/join broken ".git" "HEAD") "garbage")
  (def broken-config-dir (path/join config-dir "broken-config"))
  (sh/create-dirs broken-config-dir)
  (spit (path/join broken-config-dir "work.json")
        "[{\"path\": \"broken\", \"ssh_url\": \"b\", \"vcs\": \"git\"}]")
  (def failure
    (try (do (selection/select {:directory broken-config-dir :at-path work-dir
                                :wanted-state :dirty :jobs 1}
                               work-settings)
           nil)
      ([err] err)))
  (assert (and (dictionary? failure) (string? (failure :stage-error)))
          "the stage's own message is kept")
  (def bad-configuration
    (try (do (selection/select {:directory config-dir :at-path "/srv"}
                               (config/configured-repository-settings
                                 {:checkouts [{:from "gone.json" :anchor "/srv"}]}))
           nil)
      ([err] err)))
  (assert (string? bad-configuration) "a configuration error stays a string")
  (sh/rm broken))

(defn test-catalog-only-picks-nothing
  "Asking for the catalog alone runs no stage, whatever the filters ask."
  []
  (def result
    (work-select {:catalog-only? true :wanted-state :dirty
                  :filter-values [(string "kill -INT " (os/getpid))]}))
  (assert (not (result :interrupted?)) "no stage ran, or it would have interrupted")
  (assert (empty? (result :repositories)) "nothing is picked")
  (assert (nil? (result :reason)) "so there is nothing to explain")
  (assert (deep= @["clean" "dirty"]
                 (map (fn [repository] (path/basename (repository :path)))
                      ((result :catalog) :repositories)))
          "the catalog is whole"))

(test-catalog-only-picks-nothing)
(test-state-and-commands-narrow-the-selection)
(test-unreadable-repository-stops-the-selection)
(test-an-interrupt-stops-the-selection)
(test-nothing-configured)
(test-no-configuration-directory)

(sh/rm config-dir)
(end-suite)
