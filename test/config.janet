# Tests for reading, validating and merging repository lists.
(use spork/test)
(import spork/path)
(import spork/sh)
(import ../src/config)
(import ../src/named-filters)

(start-suite "config")

(var fixture-count 0)

(defn- fixture
  ``A fresh empty directory for one test to scribble in. Named after the
  process so parallel runs cannot collide.``
  []
  (++ fixture-count)
  (def dir (path/join (os/getenv "TMPDIR" "/tmp")
                      (string "herd-test-" (os/getpid) "-" fixture-count)))
  (sh/rm dir)
  (sh/create-dirs dir)
  # Resolved, since TMPDIR is reached through a symlink on some systems and
  # anchors are compared against paths that have theirs resolved.
  (os/realpath dir))

(defn- write-config
  "Write `entries` to `path` as the JSON array the format expects."
  [path entries]
  (sh/create-dirs-to path)
  (spit path
        (string "["
                (string/join
                  (seq [entry :in entries]
                    (string/format `{"path": %j, "ssh_url": %j%s}`
                                   (entry :path) (entry :ssh_url)
                                   (if-let [vcs-name (entry :vcs)]
                                     (string/format `, "vcs": %j` vcs-name)
                                     "")))
                  ",\n")
                "]")))

(defn- config-error
  "Return the error from checkout row resolution, or nil if it succeeds."
  [list-path checkout-rows]
  (try
    (do (config/resolve-checkout-rows list-path checkout-rows) nil)
    ([err] (string err))))

(defn- placement-paths
  "Return the paths of resolved placements, dropping their repository options."
  [placements]
  (map (fn [placement] (placement :path)) placements))

(defn- error-message
  "Return the error a thunk raises as a string, or nil when it raises none."
  [thunk]
  (try (do (thunk) nil) ([err] (string err))))

# --- validate-config ------------------------------------------------------

(assert-error "a bare object is not a configuration"
              (config/validate-repository-list {:path "a" :ssh_url "b"}))
(assert-error "entries must be objects" (config/validate-repository-list [42]))
(assert-error "path is required" (config/validate-repository-list [{:ssh_url "b"}]))
(assert-error "ssh_url is required" (config/validate-repository-list [{:path "a"}]))
(assert-error "path must be a string" (config/validate-repository-list [{:path 1 :ssh_url "b"}]))
(assert-error "vcs must be a string"
              (config/validate-repository-list [{:path "a" :ssh_url "b" :vcs :jj}]))
(assert-error "vcs cannot be false"
              (config/validate-repository-list [{:path "a" :ssh_url "b" :vcs false}]))
(assert-error "vcs must be git or jj"
              (config/validate-repository-list [{:path "a" :ssh_url "b" :vcs "svn"}]))
(assert-no-error "a well formed entry passes"
                 (config/validate-repository-list [{:path "a" :ssh_url "b"}]))
(assert-no-error "a repository can select Git"
                 (config/validate-repository-list [{:path "a" :ssh_url "b" :vcs "git"}]))
(assert-no-error "a repository can select jj"
                 (config/validate-repository-list [{:path "a" :ssh_url "b" :vcs "jj"}]))
(assert-no-error "an empty configuration is valid" (config/validate-repository-list []))
(assert-error "a repository cannot spell its URL both ways"
              (config/validate-repository-list [{:path "a" :ssh_url "b" :clone_url "b"}]))
(assert-error "clone_url must be a string"
              (config/validate-repository-list [{:path "a" :clone_url 1}]))
(let [entry (first (config/validate-repository-list
                     [{:path "a" :clone_url "b" :vcs "git"}]))]
  (assert (and (= "b" (entry :clone-url)) (= "git" (entry :vcs))
               (nil? (entry :clone_url)))
          "clone_url is the clone URL"))
(let [entry (first (config/validate-repository-list [{:path "a" :ssh_url "b"}]))]
  (assert (and (= "b" (entry :clone-url)) (nil? (entry :ssh_url)))
          "ssh_url is the clone URL too"))

# --- custom commands ------------------------------------------------------

(def reserved ["clone" "completions" "list" "run"])

(defn- prepare
  "Validate the raw settings `raw`, with the reserved command names."
  [raw]
  (config/prepare-settings raw reserved))

(defn- command-of
  "The validated custom command `name`, defined by `definition`."
  [name definition]
  (get-in (prepare {:commands {name definition}}) [:commands name]))

(assert-error "custom command JDN must be a dictionary"
              (prepare []))
(assert-error "the custom command collection must be a dictionary"
              (prepare {:commands []}))
(assert-error "a custom command cannot replace a built-in command"
              (prepare
                {:commands {"run" {:command "true" :description "Conflict."}}}))
(each name reserved
  (assert-error (string "a custom command cannot replace " name)
                (prepare
                  {:commands {name {:command "true" :description "Conflict."}}})))
(each name ["diff" "fetch"]
  (let [prepared (prepare {})]
    (assert (string? (get-in prepared [:commands name :description]))
            (string name " is a default custom command with a description")))
  (let [prepared (prepare
                   {:commands {name {:command "true" :description "Mine."}}})]
    (assert (= "Mine." (get-in prepared [:commands name :description]))
            (string "a configured " name " replaces the default"))))
(assert (= "Mine." (get (command-of "extra" {:command "true"
                                             :description "Mine."})
                        :description))
        "a configured command is added beside the defaults")
(assert-error "a custom command needs a shell command"
              (prepare
                {:commands {"check" {:description "Check repositories."}}}))
(def missing-command-message
  (try
    (do
      (prepare {:commands {"check" {:description "Check repositories."}}})
      nil)
    ([err] (string err))))
(assert (string/find ":command, :command-git, or :command-jj"
                     missing-command-message)
        "a missing command lists the valid fields")
(assert-error "a custom command needs a description"
              (prepare {:commands {"check" {:command "true"}}}))
(assert-no-error "a custom command can be jj-only"
                 (prepare
                   {:commands {"check"
                               {:command-jj "jj status"
                                :description "Check repositories."}}}))
(assert-no-error "a custom command can be Git-only"
                 (prepare
                   {:commands {"check"
                               {:command-git "git status"
                                :description "Check repositories."}}}))
(assert-error "a custom command cannot have an unknown key"
              (prepare
                {:commands {"check"
                            {:command-git "git status"
                             :comand-jj "jj status"
                             :description "Check repositories."}}}))
(each condition ["never" "on-failure" "always"]
  (assert-no-error (string "a custom command accepts show-output " condition)
                   (prepare
                     {:commands {"check" {:command "true"
                                          :description "Check repositories."
                                          :show-output condition}}})))
(assert-error "a custom command show-output condition must be a string"
              (prepare
                {:commands {"check" {:command "true"
                                     :description "Check repositories."
                                     :show-output :always}}}))
(assert-error "a custom command show-output condition must be known"
              (prepare
                {:commands {"check" {:command "true"
                                     :description "Check repositories."
                                     :show-output "sometimes"}}}))
(assert-error "a command cannot mix common and VCS-specific forms"
              (prepare
                {:commands {"check"
                            {:command "status"
                             :command-git "git status"
                             :command-jj "jj status"
                             :description "Check repositories."}}}))
(assert (= 6 ((prepare {}) :jobs)) "six jobs is the default")
(assert (= 3 ((prepare {:jobs 3}) :jobs)) "a job count can be configured")
(each invalid [0 -2 1.5 "4" :four 2147483648]
  (assert-error (string "a configured job count rejects " (describe invalid))
                (prepare {:jobs invalid})))

(let [command (command-of "check" {:command "true"
                                   :description "Check repositories."})]
  (assert (= "Check repositories." (command :description))
          "a custom command retains its description")
  (assert (= "true" (command :command)) "and its command")
  (assert (= "on-failure" (command :show-output))
          "and settles the output to show when none is configured"))

(assert (deep= {:command-git "git status" :command-jj "jj status"}
               (get (command-of "check"
                                {:command-git "git status"
                                 :command-jj "jj status"
                                 :description "Check."})
                    :command))
        "VCS-specific configuration becomes a per-repository command")
(assert (deep= {:command-jj "jj status"}
               (get (command-of "check"
                                {:command-jj "jj status" :description "Check."})
                    :command))
        "a VCS-specific command can support only jj")
(assert-error "a definition needs a description"
              (command-of "check" {:command "true"}))
(assert-error "a definition show-output condition must be known"
              (command-of "check" {:command "true"
                                   :description "Check."
                                   :show-output "sometimes"}))

(assert-error "a custom command name must be a non-empty string"
              (command-of "" {:command "true" :description "x"}))
(assert-error "a custom command definition must be a dictionary"
              (command-of "check" "true"))
(assert-error "a custom command definition cannot have an unknown key"
              (command-of "check" {:command "true" :comand-jj "jj status"}))

(let [dir (fixture)
      settings-path (path/join dir "config.jdn")]
  (spit settings-path `(error "this code must not run")`)
  (def message
    (try
      (do (config/load-settings dir reserved) nil)
      ([err] (string err))))
  (assert (and message (string/find "expected a JDN dictionary" message))
          "loading JDN parses an expression as data instead of running it")
  (sh/rm dir))

(let [dir (fixture)
      settings-path (path/join dir "config.jdn")]
  (spit settings-path `{:checkout-defaults {:vcs "git"}}`)
  (assert (= "git" (get-in (config/load-settings dir reserved)
                           [:settings :checkout-defaults :vcs]))
          "the default VCS is loaded from config.jdn")
  (sh/rm dir))

# --- load-settings --------------------------------------------------------

(let [dir (fixture)]
  (def loaded (config/load-settings dir reserved))
  (assert (= 6 (loaded :jobs)) "an absent file reads as the defaults")
  (assert (get-in loaded [:commands "diff"]) "with the default commands")
  (assert (empty? (get-in loaded [:settings :checkouts])) "and no checkouts")
  (def unconfigured (config/load-settings nil reserved))
  (assert (= 6 (unconfigured :jobs)) "no directory to read is no settings either")
  (sh/create-dirs (path/join dir "config.jdn"))
  (def message
    (try (do (config/load-settings dir reserved) nil) ([err] (string err))))
  (assert (and message (string/find "is not a file" message)
               (string/find (path/join dir "config.jdn") message))
          "a directory where the file belongs is named")
  (sh/rm dir))

(let [dir (fixture)]
  (spit (path/join dir "config.jdn") "{:jobs 0}")
  (def message
    (try (do (config/load-settings dir reserved) nil) ([err] (string err))))
  (assert (and message (string/has-prefix? (path/join dir "config.jdn") message)
               (string/find ":jobs must be a positive integer" message))
          "a mistake in the file is reported with the file's path first")
  (sh/rm dir))

(let [xdg (os/getenv "XDG_CONFIG_HOME")]
  (os/setenv "XDG_CONFIG_HOME" "/xdg")
  (assert (= "/xdg/herd/config.jdn" (config/settings-file-path))
          "the file is config.jdn in the configuration directory")
  (os/setenv "XDG_CONFIG_HOME" xdg))

# --- parse-settings-file -------------------------------------------------------

(assert (deep= {:jobs 3} (config/parse-settings-file `{:jobs 3}`))
        "one dictionary is the settings it holds")
(assert (deep= {} (config/parse-settings-file ""))
        "an empty file holds no settings")

# A second dictionary appended rather than merged used to be read as far as
# the first and the rest dropped in silence.
(let [dir (fixture)
      settings-path (path/join dir "config.jdn")]
  (spit settings-path
        (string `{:jobs 3}` "\n\n"
                `{:commands {"hi" {:command "echo hi" :description "say hi"}}}`))
  (def message
    (try
      (do (config/load-settings dir reserved) nil)
      ([err] (string err))))
  (assert (and message (string/find "2 top-level values" message))
          "settings split across two dictionaries are refused, not truncated")
  (sh/rm dir))

(let [dir (fixture)
      settings-path (path/join dir "config.jdn")]
  (spit settings-path "# nothing configured yet\n")
  (def settings (get (config/load-settings dir reserved) :settings))
  (assert (and (empty? (settings :checkout-defaults))
               (empty? (settings :checkouts))
               (empty? (settings :filters)))
          "a file with no settings in it reads as no settings")
  (sh/rm dir))

# --- resolve-repository-paths ---------------------------------------------

(let [entries (config/resolve-repository-paths
                [{:path "rel" :clone-url "u"}
                 {:path "/already/absolute" :clone-url "u"}]
                @[{:path "/anchor" :strip-components 0}])]
  (assert (= "/anchor/rel" ((entries 0) :path)) "a relative path joins the anchor")
  (assert (= "/already/absolute" ((entries 1) :path)) "an absolute path is left alone")
  (assert (deep= @["/anchor"] ((entries 0) :anchors))
          "resolved entries retain their configuration anchor")
  (assert (= "u" ((entries 0) :clone-url)) "the rest of the entry survives")
  (assert (= :vcs/jj ((entries 0) :vcs))
          "a checkout no level settles is a jj checkout"))

(let [entries (config/resolve-repository-paths
                [{:path "org/team/repo" :clone-url "relative"}
                 {:path "/srv/other/repo" :clone-url "absolute"}]
                @[{:path "/anchor" :strip-components 1}])]
  (assert (deep= @["/anchor/team/repo" "/anchor/other/repo"]
                 (map (fn [repository] (repository :path)) entries))
          "stripping makes relative and absolute paths relative to the anchor"))

(let [message
      (error-message
        (fn [] (config/resolve-repository-paths
                 [{:path "team/repo" :clone-url "u"}]
                 @[{:path "/anchor" :strip-components 2}])))]
  (assert (and message
               (string/find "2" message)
               (string/find `"team/repo"` message)
               (string/find `"/anchor"` message))
          "stripping a complete path names its row, count and path in the error"))

(assert-error "stripping more components than a path has fails"
              (config/resolve-repository-paths
                [{:path "team/repo" :clone-url "u"}]
                @[{:path "/anchor" :strip-components 3}]))

(let [entries (config/resolve-repository-paths
                [{:path "plain" :clone-url "u"}
                 {:path "own" :clone-url "u" :vcs "jj"}]
                @[{:path "/anchor" :vcs "git"}])]
  (assert (= :vcs/git ((entries 0) :vcs)) "an anchor settles the VCS beneath it")
  (assert (= :vcs/jj ((entries 1) :vcs)) "an entry overrides the anchor it is under"))

(assert (empty? (config/resolve-repository-paths
                  [{:path "rel" :clone-url "u"}
                   {:path "/already/absolute" :clone-url "u"}]
                  @[]))
        "entries anchored nowhere resolve to no repositories")

(let [entries (config/resolve-repository-paths
                [{:path "rel" :clone-url "u"}]
                @[{:path "/one"} {:path "/two"}])]
  (assert (= 2 (length entries)) "every anchor resolves the same entry once")
  (assert (deep= @["/one/rel" "/two/rel"] (map (fn [repository] (repository :path)) entries))
          "a relative path joins each anchor in turn")
  (assert (deep= @[@["/one"] @["/two"]] (map (fn [repository] (repository :anchors)) entries))
          "each resolved entry keeps the anchor it came from"))

# --- config-directory -----------------------------------------------------

(let [home (os/getenv "HOME")
      xdg (os/getenv "XDG_CONFIG_HOME")]
  (os/setenv "XDG_CONFIG_HOME" "/x")
  (assert (= "/x/herd" (config/config-directory)) "XDG_CONFIG_HOME wins")
  (os/setenv "XDG_CONFIG_HOME" nil)
  (os/setenv "HOME" "/h")
  (assert (= "/h/.config/herd" (config/config-directory)) "HOME is the fallback")
  (os/setenv "HOME" nil)
  (assert (nil? (config/config-directory)) "neither set means no directory")
  (os/setenv "HOME" home)
  (os/setenv "XDG_CONFIG_HOME" xdg))

# --- discover-repository-lists ------------------------------------------------

(let [dir (fixture)]
  (assert (empty? (config/discover-repository-lists (string dir "/missing")))
          "a missing directory holds no configuration")
  (assert (empty? (config/discover-repository-lists nil)) "no directory at all holds none")
  (spit (string dir "/b.json") "[]")
  (spit (string dir "/a.json") "[]")
  (spit (string dir "/notes.txt") "ignored")
  (sh/create-dirs (string dir "/directory.json"))
  (sh/create-dirs (string dir "/root"))
  (os/link (string dir "/root") (string dir "/a.json.root") true)
  (assert (deep= (config/discover-repository-lists dir)
                 @[(string dir "/a.json") (string dir "/b.json")])
          "repository JSON files are sorted without directories")
  (sh/rm dir))

# A directory herd cannot read holds every repository it would otherwise
# report as gone, so it has to say so rather than pass for an empty one.
(let [dir (fixture)
      closed (string dir "/closed")]
  (sh/create-dirs closed)
  (spit (string closed "/a.json") "[]")
  (os/chmod closed 8r000)
  # A user who can read it anyway, root among them, has nothing to check.
  (when (try (do (os/dir closed) false) ([_] true))
    (def message
      (try
        (do (config/discover-repository-lists closed) nil)
        ([err] (string err))))
    (assert (and message (string/find closed message))
            "an unreadable directory raises and names itself"))
  (os/chmod closed 8r755)
  (sh/rm dir))

# A closed parent hides the directory the same way, and os/stat cannot tell
# that apart from a directory nobody has created yet.
(let [dir (fixture)
      outer (string dir "/outer")
      inner (string outer "/herd")]
  (sh/create-dirs inner)
  (spit (string inner "/a.json") "[]")
  (os/chmod outer 8r000)
  (when (try (do (os/dir inner) false) ([_] true))
    (assert-error "a directory under a closed parent raises"
                  (config/discover-repository-lists inner)))
  (os/chmod outer 8r755)
  (sh/rm dir))

(let [dir (fixture)
      afile (string dir "/a-file")]
  (spit afile "not a directory")
  (assert-error "a file where the configuration directory belongs raises"
                (config/discover-repository-lists afile))
  (sh/rm dir))

# --- checkout rows --------------------------------------------------------

(assert-error "a row must be a dictionary"
              (config/validate-checkout-row [] ":checkouts row 0"))
(assert-error "a row needs a source"
              (config/validate-checkout-row {:anchor "work"} ":checkouts row 0"))
(assert-error "a row source must be a string"
              (config/validate-checkout-row {:list 1} ":checkouts row 0"))
(assert-error "a row source must not be empty"
              (config/validate-checkout-row {:list ""} ":checkouts row 0"))
(assert-no-error "a row may hold its repositories inline"
                 (config/validate-checkout-row {:list [{:path "a" :clone-url "b"}]}
                                               ":checkouts row 0"))
(assert-no-error "an inline list may be empty"
                 (config/validate-checkout-row {:list []} ":checkouts row 0"))
(assert-error "a row anchor must be a string"
              (config/validate-checkout-row {:list "a.json" :anchor 1}
                                            ":checkouts row 0"))
(assert-error "a row anchor must not be empty"
              (config/validate-checkout-row {:list "a.json" :anchor ""}
                                            ":checkouts row 0"))
(assert-error "a row rejects settings it cannot carry"
              (config/validate-checkout-row {:list "a.json" :jobs 2}
                                            ":checkouts row 0"))
(assert-error "the anchors an anchor replaced are not a row setting"
              (config/validate-checkout-row {:list "a.json" :anchors ["work"]}
                                            ":checkouts row 0"))
(assert-error "a row VCS must be git or jj"
              (config/validate-checkout-row {:list "a.json" :vcs "svn"}
                                            ":checkouts row 0"))
(assert-error "a row strip count must be an integer"
              (config/validate-checkout-row
                {:list "a.json" :strip-components 1.5}
                ":checkouts row 0"))
(assert-error "a row strip count must not be a string"
              (config/validate-checkout-row
                {:list "a.json" :strip-components "1"}
                ":checkouts row 0"))
(assert-error "a row strip count must not be negative"
              (config/validate-checkout-row
                {:list "a.json" :strip-components -1}
                ":checkouts row 0"))
(assert-no-error "a source alone is a valid row"
                 (config/validate-checkout-row {:list "a.json"}
                                               ":checkouts row 0"))
(assert-no-error "a row can strip no path components"
                 (config/validate-checkout-row
                   {:list "a.json" :strip-components 0}
                   ":checkouts row 0"))
(assert-no-error "a row can strip path components"
                 (config/validate-checkout-row
                   {:list "a.json" :strip-components 2}
                   ":checkouts row 0"))
(assert-no-error "a row settles an anchor and a VCS"
                 (config/validate-checkout-row
                   {:list "a.json" :anchor "/srv" :vcs "git"}
                   ":checkouts row 0"))

(let [message (error-message
                (fn [] (config/validate-checkout-row {:unknown true}
                                                     ":checkouts row 2")))]
  (assert (and message (string/find ":checkouts row 2" message))
          "a row error names the row it came from"))

(assert-error "the defaults must be a dictionary"
              (config/validate-checkout-defaults []))
(assert-error "the defaults cannot name a source"
              (config/validate-checkout-defaults {:list "a.json"}))
(assert-error "the defaults reject settings they cannot carry"
              (config/validate-checkout-defaults {:jobs 2}))
(assert-error "the defaults cannot strip path components"
              (config/validate-checkout-defaults {:strip-components 1}))
(assert-error "a default anchor must not be empty"
              (config/validate-checkout-defaults {:anchor ""}))
(assert-error "a default VCS must be git or jj"
              (config/validate-checkout-defaults {:vcs "svn"}))
(assert-no-error "empty defaults are valid"
                 (config/validate-checkout-defaults {}))
(assert-error "a default anchor cannot be true"
              (config/validate-checkout-defaults {:anchor true}))
(assert-no-error "a default anchor can be disabled with false"
                 (config/validate-checkout-defaults {:anchor false}))
(assert-error "a row cannot disable its anchor"
              (config/validate-checkout-row {:list "a.json" :anchor false} "row"))
(assert-no-error "the defaults settle an anchor and a VCS"
                 (config/validate-checkout-defaults {:anchor "src" :vcs "git"}))

# --- configured-repository-settings ---------------------------------------

(assert-error "the JDN configuration must be a dictionary"
              (config/configured-repository-settings []))
(assert-error "the checkouts must be an array"
              (config/configured-repository-settings {:checkouts {}}))
(assert-error "every row is validated"
              (config/configured-repository-settings
                {:checkouts [{:list "work.json"} {:unknown true}]}))
(assert-error "the defaults are validated"
              (config/configured-repository-settings {:checkout-defaults {:vcs "svn"}}))
(assert-no-error "a configuration need settle nothing"
                 (config/configured-repository-settings {}))

(let [settings (config/configured-repository-settings
                 {:checkouts [{:list "work.json" :anchor "work"}
                              {:list "vendor.json" :anchor "/opt"}
                              {:list "work.json" :anchor "/srv" :vcs "git"}]})]
  (assert (deep= @["work" "/opt" "/srv"]
                 (map (fn [checkout] (checkout :anchor)) (settings :checkouts)))
          "rows are kept in the order they were written")
  (assert (deep= @["work" "/srv"]
                 (map (fn [checkout] (checkout :anchor)) (config/checkout-rows-for-list settings "work.json")))
          "a file reads only the rows that name it"))


# --- filter settings ------------------------------------------------------

(assert-error "a row filter must be an array, not a bare name"
              (config/validate-checkout-row {:list "a.json" :use-filters "active"}
                                            ":checkouts row 0"))
(assert-error "a row filter names strings"
              (config/validate-checkout-row {:list "a.json" :use-filters [1]}
                                            ":checkouts row 0"))
(assert-error "a row filter name must not be empty"
              (config/validate-checkout-row {:list "a.json" :use-filters [""]}
                                            ":checkouts row 0"))
(assert-no-error "a row filters by an array of names"
                 (config/validate-checkout-row
                   {:list "a.json" :use-filters ["active" "platform"]}
                   ":checkouts row 0"))
(assert-no-error "a row can filter by nothing at all"
                 (config/validate-checkout-row {:list "a.json" :use-filters []}
                                               ":checkouts row 0"))
(assert-error "a default filter must be an array too"
              (config/validate-checkout-defaults {:use-filters "active"}))
(assert-no-error "the defaults settle filters"
                 (config/validate-checkout-defaults {:use-filters ["active"]}))

(let [settings (config/configured-repository-settings
                 {:filters {"a" "[?a]" "b" {:jp "[?b]"} "c" {:sh "true"}}})]
  (assert (and (named-filters/list-filter? (settings :filters) "a")
               (named-filters/list-filter? (settings :filters) "b"))
          "strings and :jp filters are the JMESPath expressions")
  (assert (= "true" (named-filters/checkout-filter-command (settings :filters) "c"))
          "shell filters keep their commands in the same registry")
  (assert (nil? (settings :sh-filters)) "there is one registry, not two"))
(assert-error "a row cannot name a shell filter"
              (config/configured-repository-settings
                {:filters {"c" {:sh "true"}}
                 :checkouts [{:list "work.json" :use-filters ["c"]}]}))
(assert-error "the defaults cannot name a shell filter"
              (config/configured-repository-settings
                {:filters {"c" {:sh "true"}} :checkout-defaults {:use-filters ["c"]}}))

(assert-error "a row cannot name a filter that is not configured"
              (config/configured-repository-settings
                {:checkouts [{:list "work.json" :use-filters ["absent"]}]}))
(assert-error "the defaults cannot name a filter that is not configured"
              (config/configured-repository-settings {:checkout-defaults {:use-filters ["absent"]}}))
(let [message (error-message
                (fn [] (config/configured-repository-settings
                         {:filters {"active" "[?a]"}
                          :checkouts [{:list "work.json" :use-filters ["typo"]}]})))]
  (assert (and message (string/find `"typo"` message))
          "an unknown filter is named rather than the whole row"))

(let [settings (config/configured-repository-settings
                 {:filters {"active" "[?a]" "platform" "[?b]"}
                  :checkout-defaults {:use-filters ["active"]}
                  :checkouts [{:list "work.json"}
                              {:list "work.json" :use-filters ["platform"]}
                              {:list "work.json" :use-filters []}]})
      checkouts (config/checkout-rows-for-list settings "work.json")]
  (assert (deep= {"active" "[?a]" "platform" "[?b]"} (settings :filters))
          "the registry is carried with the settings")
  (assert (deep= ["active"] ((checkouts 0) :use-filters))
          "a row that names no filter inherits the default one")
  (assert (deep= ["platform"] ((checkouts 1) :use-filters))
          "a row that names filters replaces the default ones")
  (assert (empty? ((checkouts 2) :use-filters))
          "and an empty array drops them without naming another"))
# --- checkout-rows-for-list --------------------------------------------------------

(let [settings (config/configured-repository-settings
                 {:checkout-defaults {:anchor "src" :vcs "jj"}
                  :checkouts [{:list "work.json" :anchor "work"}
                              {:list "work.json" :anchor "/srv" :vcs "git"}]})
      unmentioned (config/checkout-rows-for-list settings "other.json")
      work (config/checkout-rows-for-list settings "work.json")]
  (assert (= 1 (length unmentioned))
          "a file no row reads is checked out once")
  (assert (= "src" ((unmentioned 0) :anchor))
          "and takes its anchor from the defaults")
  (assert (= "jj" ((unmentioned 0) :vcs))
          "along with the rest of them")
  (assert (deep= @["work" "/srv"] (map (fn [checkout] (checkout :anchor)) work))
          "a file its rows read is checked out once per row")
  (assert (= "jj" ((work 0) :vcs))
          "a row keeps the defaults it does not name")
  (assert (= "git" ((work 1) :vcs))
          "and replaces the ones it does"))

(let [checkouts (config/checkout-rows-for-list config/default-repository-settings "any.json")]
  (assert (= 1 (length checkouts)) "without a configuration every file is read once")
  (assert (nil? ((checkouts 0) :anchor))
          "and settles no anchor, leaving its own location to decide"))


(let [dir (fixture)
      configuration (string dir "/config/herd")
      elsewhere (string dir "/elsewhere")
      home (os/getenv "HOME")]
  (sh/create-dirs configuration)
  (sh/create-dirs elsewhere)
  (spit (string configuration "/real.json") "[]")
  (spit (string elsewhere "/linked.json") "[]")
  (os/link (string elsewhere "/linked.json") (string configuration "/link.json") true)

  (os/setenv "HOME" "/home/example")
  (assert (deep= @["/home/example"]
                 (placement-paths
                   (config/resolve-checkout-rows (string configuration "/real.json") @[{}])))
          "a file in the configuration directory anchors at home")
  (assert (deep= @["/home/example"]
                 (placement-paths
                   (config/resolve-checkout-rows (string configuration "/link.json") @[{}])))
          "a JSON symlink uses its visible location")
  (assert (deep= @["/home/example/work"]
                 (placement-paths
                   (config/resolve-checkout-rows (string configuration "/real.json") @[{:anchor "work"}])))
          "a relative configured anchor resolves from home")
  (assert (deep= @["/home/example/work" "/srv/shared"]
                 (placement-paths
                   (config/resolve-checkout-rows (string configuration "/real.json")
                                                 @[{:anchor "work"}
                                                   {:anchor "/srv/shared"}])))
          "every row is resolved in the order it was written")
  (assert (deep= @[]
                 (placement-paths
                   (config/resolve-checkout-rows (string configuration "/real.json") @[])))
          "a file no row reads is anchored nowhere")
  (assert (deep= @["/missing/anchor"]
                 (placement-paths
                   (config/resolve-checkout-rows (string configuration "/real.json")
                                                 @[{:anchor "/missing/anchor"}])))
          "an absolute configured anchor need not exist")

  # A row carries the repository options it was merged with, and nothing else.
  (let [placements (config/resolve-checkout-rows (string configuration "/real.json")
                                                 @[{:anchor "work" :vcs "git"}
                                                   {:anchor "/srv" :vcs "jj"}])]
    (assert (deep= @["/home/example/work" "/srv"] (placement-paths placements))
            "each row is resolved on its own")
    (assert (= "git" ((placements 0) :vcs)) "keeping the options it settles")
    (assert (= "jj" ((placements 1) :vcs)) "one row at a time"))
  (let [placements (config/resolve-checkout-rows (string configuration "/real.json") @[{:anchor "work"}])]
    (assert (nil? ((placements 0) :vcs))
            "a row settling no options carries none at all"))

  (sh/create-dirs (string elsewhere "/work"))
  (os/link elsewhere (string dir "/link") true)
  (assert (deep= @[(string dir "/link/work")]
                 (placement-paths
                   (config/resolve-checkout-rows (string configuration "/real.json")
                                                 @[{:anchor (string dir "/link/work")}])))
          "a configured anchor is kept as it was written, symlinks and all")

  (os/setenv "HOME" nil)
  (def default-message
    (config-error (string configuration "/real.json") @[{}]))
  (assert (and default-message (string/find "without HOME" default-message))
          "the default anchor needs home")
  (def message
    (config-error (string configuration "/real.json")
                  @[{:anchor "work"}]))
  (assert (and message (string/find "without HOME" message))
          "a relative configured anchor needs home")
  (os/setenv "HOME" "/home/example")
  (def disabled-message
    (config-error (string configuration "/real.json")
                  @[{:anchor false}]))
  (assert (and disabled-message (string/find "default anchor" disabled-message))
          "a disabled default anchor leaves a configured file unplaced")
  (assert (deep= @["/srv/shared"]
                 (placement-paths
                   (config/resolve-checkout-rows (string configuration "/real.json")
                                                 @[{:anchor "/srv/shared"}])))
          "a row still anchors a list when the default anchor is disabled")
  (os/setenv "HOME" home)
  (sh/rm dir))

(let [dir (fixture)
      configuration (string dir "/config/herd")
      config (string configuration "/repos.json")
      home (os/getenv "HOME")]
  (sh/create-dirs configuration)
  (write-config config
                [{:path "relative" :ssh_url "relative-url"}
                 {:path "/absolute" :ssh_url "absolute-url"}])
  (os/setenv "HOME" dir)
  (let [repositories (config/load-repository-lists
                       [config]
                       (config/configured-repository-settings
                         {:checkouts [{:list "repos.json" :anchor "root"}]}))]
    (assert (= (string (path/abspath dir) "/root/relative")
               ((repositories 0) :path))
            "relative paths use the configured anchor")
    (assert (= "/absolute" ((repositories 1) :path))
            "absolute paths ignore the configured anchor")
    (assert (deep= @[(string (path/abspath dir) "/root")]
                   ((repositories 0) :anchors))
            "the configured anchor is retained on each repository"))
  (os/setenv "HOME" home)
  (sh/rm dir))

(let [dir (fixture)
      configuration (string dir "/config/herd")
      config (string configuration "/repos.json")
      home (os/getenv "HOME")]
  (sh/create-dirs configuration)
  (write-config config
                [{:path "relative" :ssh_url "relative-url"}
                 {:path "/absolute" :ssh_url "absolute-url"}])
  (os/setenv "HOME" dir)
  (let [repositories (config/load-repository-lists
                       [config]
                       (config/configured-repository-settings
                         {:checkouts [{:list "repos.json" :anchor "one"}
                                      {:list "repos.json" :anchor "two"}]}))
        root (path/abspath dir)]
    (assert (= 3 (length repositories))
            "several rows check the relative tree out at each of their anchors")
    (assert (deep= @[(string root "/one/relative")
                     "/absolute"
                     (string root "/two/relative")]
                   (map (fn [repository] (repository :path)) repositories))
            "each anchor contributes its own resolved paths")
    (assert (deep= @[(string root "/one")] ((repositories 0) :anchors))
            "a relative path belongs to the anchor it resolved under")
    (assert (deep= @[(string root "/one") (string root "/two")]
                   ((repositories 1) :anchors))
            "an absolute path stays one repository under every anchor"))
  (os/setenv "HOME" home)
  (sh/rm dir))

(let [dir (fixture)
      configuration (string dir "/config/herd")
      config (string configuration "/repos.json")
      home (os/getenv "HOME")]
  (sh/create-dirs configuration)
  (write-config config [{:path "org/team/repo" :ssh_url "url"}])
  (os/setenv "HOME" dir)
  (let [repositories (config/load-repository-lists
                       [config]
                       (config/configured-repository-settings
                         {:checkouts
                          [{:list "repos.json" :anchor "one" :strip-components 1}
                           {:list "repos.json" :anchor "two" :strip-components 2}]}))
        root (path/abspath dir)]
    (assert (deep= @[(string root "/one/team/repo")
                     (string root "/two/repo")]
                   (map (fn [repository] (repository :path)) repositories))
            "each row strips its own number of path components"))
  (os/setenv "HOME" home)
  (sh/rm dir))

(let [dir (fixture)
      configuration (string dir "/config/herd")
      unread (string configuration "/first.json")
      read-by-a-row (string configuration "/second.json")
      home (os/getenv "HOME")]
  (sh/create-dirs configuration)
  (write-config unread [{:path "one" :ssh_url "one-url"}])
  (write-config read-by-a-row [{:path "two" :ssh_url "two-url"}])
  (os/setenv "HOME" dir)
  (let [repositories (config/load-repository-lists
                       (config/discover-repository-lists configuration)
                       (config/configured-repository-settings
                         {:checkout-defaults {:anchor "root"}
                          :checkouts [{:list "second.json" :anchor "elsewhere"}]}))
        root (path/abspath dir)]
    (assert (deep= @[(string root "/root/one") (string root "/elsewhere/two")]
                   (map (fn [repository] (repository :path)) repositories))
            "a file no row reads resolves from the defaults alone"))
  (assert-error "a row reading a file that is not there is refused"
                (config/load-repository-lists
                  (config/discover-repository-lists configuration)
                  (config/configured-repository-settings
                    {:checkouts [{:list "renamed.json" :anchor "root"}]})))
  (os/setenv "HOME" home)
  (sh/rm dir))

# Resolve the VCS from the entry, then the row, then the defaults.
(let [dir (fixture)
      configuration (string dir "/config/herd")
      config (string configuration "/repos.json")
      home (os/getenv "HOME")]
  (sh/create-dirs configuration)
  (spit config
        `[{"path": "plain", "ssh_url": "u"},
          {"path": "own", "ssh_url": "u", "vcs": "jj"}]`)
  (os/setenv "HOME" dir)
  (let [repositories (config/load-repository-lists
                       [config]
                       (config/configured-repository-settings
                         {:checkout-defaults {:vcs "jj"}
                          :checkouts [{:list "repos.json" :anchor "a" :vcs "git"}
                                      {:list "repos.json" :anchor "b"}]}))]
    (assert (deep= @[:vcs/git :vcs/jj :vcs/jj :vcs/jj] (map (fn [repository] (repository :vcs)) repositories))
            "each level overrides the one it sits inside"))
  (os/setenv "HOME" home)
  (sh/rm dir))

(let [dir (fixture)
      configuration (string dir "/config/herd")
      target (string dir "/target")
      regular (string configuration "/regular.json")
      broken (string configuration "/broken.json")
      directory (string configuration "/directory.json")
      home (os/getenv "HOME")]
  (sh/create-dirs configuration)
  (spit target "not a directory")
  (each list-path [regular broken directory]
    (write-config list-path [{:path (path/basename list-path) :ssh_url "u"}]))
  (spit (string regular ".root") "not a symlink")
  (os/link (string dir "/missing") (string broken ".root") true)
  (os/link target (string directory ".root") true)
  (os/setenv "HOME" dir)
  (let [repositories (config/load-repository-lists
                       (config/discover-repository-lists configuration))]
    (assert (= 3 (length repositories)) "root companions do not affect loading")
    (assert (every?
              (map (fn [repository] (string/has-prefix? (string (path/abspath dir) "/") (repository :path)))
                   repositories))
            "every root companion form is ignored"))
  (os/setenv "HOME" home)
  (sh/rm dir))

# --- read-repository-list and load-repository-lists ------------------------------------------

(let [dir (fixture)
      configuration (string dir "/config/herd")
      elsewhere (string dir "/elsewhere")
      home (os/getenv "HOME")]
  (sh/create-dirs configuration)
  (sh/create-dirs elsewhere)
  (os/setenv "HOME" dir)

  (write-config (string configuration "/a.json")
                [{:path "src/alpha" :ssh_url "git@example.com:alpha.git"}
                 {:path "/opt/beta" :ssh_url "git@example.com:beta.git"}])
  (write-config (string elsewhere "/b.json")
                [{:path "gamma" :ssh_url "git@example.com:gamma.git"}])
  (os/link (string elsewhere "/b.json") (string configuration "/link.json") true)

  (let [merged (config/load-repository-lists (config/discover-repository-lists configuration))]
    (assert (deep= (map (fn [repository] (repository :path)) merged)
                   @[(string dir "/src/alpha")
                     "/opt/beta"
                     (string dir "/gamma")])
            "every file contributes from its visible configuration location"))

  # The same checkout in two files is fine while they agree on the URL.
  (write-config (string configuration "/agrees.json")
                [{:path "src/alpha" :ssh_url "git@example.com:alpha.git"}])
  (assert (= 3 (length (config/load-repository-lists (config/discover-repository-lists configuration))))
          "an agreeing duplicate is dropped")

  (write-config (string configuration "/agrees.json")
                [{:path "src/alpha" :ssh_url "git@example.com:different.git"}])
  (assert-error "a disagreeing duplicate is refused"
                (config/load-repository-lists (config/discover-repository-lists configuration)))

  # Two files may name one checkout only while they agree on every checkout
  # option, not merely on the URL. src/alpha carries no vcs of its own above,
  # so it is checked out with the default jj.
  (write-config (string configuration "/agrees.json")
                [{:path "src/alpha" :ssh_url "git@example.com:alpha.git"
                  :vcs "git"}])
  (assert-error "a duplicate disagreeing about the vcs is refused"
                (config/load-repository-lists (config/discover-repository-lists configuration)))

  (write-config (string configuration "/agrees.json")
                [{:path "src/alpha" :ssh_url "git@example.com:alpha.git"
                  :vcs "jj"}])
  (assert (= 3 (length (config/load-repository-lists (config/discover-repository-lists configuration))))
          "a duplicate naming the vcs it already has is dropped")

  (assert-error "an unreadable file is refused"
                (config/load-repository-lists [(string dir "/absent.json")]))
  (os/setenv "HOME" home)
  (sh/rm dir))

(let [dir (fixture)
      configuration (string dir "/config/herd")
      config (string configuration "/repos.json")
      settings (config/configured-repository-settings
                 {:checkouts [{:list "repos.json"
                               :anchor "root"
                               :strip-components 1}]})]
  (sh/create-dirs configuration)
  (write-config config
                [{:path "one/repo" :ssh_url "shared-url"}
                 {:path "two/repo" :ssh_url "shared-url"}])
  (assert (= 1 (length (config/load-repository-lists [config] settings)))
          "agreeing paths merged by stripping remain one repository")
  (write-config config
                [{:path "one/repo" :ssh_url "first-url"}
                 {:path "two/repo" :ssh_url "second-url"}])
  (assert-error "stripped paths with different URLs are refused"
                (config/load-repository-lists [config] settings))
  (sh/rm dir))

(let [dir (fixture)
      first (string dir "/first.json")
      second (string dir "/second.json")
      checkout (string dir "/shared")]
  (write-config first [{:path checkout :ssh_url "shared-url"}])
  (write-config second [{:path checkout :ssh_url "shared-url"}])
  (let [repositories (config/load-repository-lists
                       [first second]
                       (config/configured-repository-settings
                         {:checkouts [{:list "first.json" :anchor "/one"}
                                      {:list "second.json" :anchor "/two"}]}))]
    (assert (= 1 (length repositories)) "an agreeing duplicate remains one repository")
    (assert (deep= @["/one" "/two"] ((repositories 0) :anchors))
            "an agreeing duplicate retains every configuration anchor"))
  (sh/rm dir))

# --- load-repository-catalog ---------------------------------------------

(let [dir (fixture)
      configuration (string dir "/config/herd")
      config (string configuration "/repos.json")]
  (sh/create-dirs configuration)
  (write-config config [{:path "/abs/one" :ssh_url "one-url"}])
  (let [catalog (config/load-repository-catalog configuration nil)]
    (assert (= configuration (catalog :directory))
            "the catalog keeps the configuration directory")
    (assert (deep= @[config] (catalog :repository-lists))
            "the catalog keeps the repository lists it read")
    (assert (deep= @["/abs/one"]
                   (map (fn [repository] (repository :path))
                        (catalog :repositories)))
            "the catalog holds the merged repositories"))
  (let [catalog (config/load-repository-catalog (string dir "/missing") nil)]
    (assert (and (empty? (catalog :repository-lists)) (empty? (catalog :repositories)))
            "a missing directory yields an empty catalog"))
  (assert (try (do (config/load-repository-catalog
                     configuration
                     (config/configured-repository-settings
                       {:checkouts [{:list "absent.json" :anchor "root"}]}))
                 false)
            ([_] true))
          "a checkout from an absent file is a configuration error")
  (sh/rm dir))

(end-suite)
