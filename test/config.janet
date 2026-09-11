# Tests for reading, validating and merging configuration files.
(use spork/test)
(import spork/path)
(import spork/sh)
(import ../main :as herd)

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
                    (string/format `{"path": %j, "ssh_url": %j}`
                                   (entry :path) (entry :ssh_url)))
                  ",\n")
                "]")))

(defn- config-error
  "Return the error from config anchor resolution, or nil if it succeeds."
  [config-path directory rows]
  (try
    (do (herd/config-anchors config-path directory rows) nil)
    ([err] (string err))))

(defn- anchor-paths
  "Return the paths of resolved anchors, dropping their checkout options."
  [anchors]
  (map |($ :path) anchors))

(defn- error-message
  "Return the error a thunk raises as a string, or nil when it raises none."
  [thunk]
  (try (do (thunk) nil) ([err] (string err))))

# --- validate-config ------------------------------------------------------

(assert-error "a bare object is not a configuration"
              (herd/validate-config {:path "a" :ssh_url "b"}))
(assert-error "entries must be objects" (herd/validate-config [42]))
(assert-error "path is required" (herd/validate-config [{:ssh_url "b"}]))
(assert-error "ssh_url is required" (herd/validate-config [{:path "a"}]))
(assert-error "path must be a string" (herd/validate-config [{:path 1 :ssh_url "b"}]))
(assert-error "vcs must be a string"
              (herd/validate-config [{:path "a" :ssh_url "b" :vcs :jj}]))
(assert-error "vcs cannot be false"
              (herd/validate-config [{:path "a" :ssh_url "b" :vcs false}]))
(assert-error "vcs must be git or jj"
              (herd/validate-config [{:path "a" :ssh_url "b" :vcs "svn"}]))
(assert-no-error "a well formed entry passes"
                 (herd/validate-config [{:path "a" :ssh_url "b"}]))
(assert-no-error "a repository can select Git"
                 (herd/validate-config [{:path "a" :ssh_url "b" :vcs "git"}]))
(assert-no-error "a repository can select jj"
                 (herd/validate-config [{:path "a" :ssh_url "b" :vcs "jj"}]))
(assert-no-error "an empty configuration is valid" (herd/validate-config []))

# --- custom-commands ------------------------------------------------------

(assert-error "custom command JDN must be a dictionary"
              (herd/custom-commands []))
(assert-error "the custom command collection must be a dictionary"
              (herd/custom-commands {:commands []}))
(assert-error "a custom command cannot replace a built-in command"
              (herd/custom-commands
                {:commands {"run" {:command "true" :description "Conflict."}}}))
(assert-error "a custom command needs a shell command"
              (herd/custom-commands
                {:commands {"check" {:description "Check repositories."}}}))
(def missing-command-message
  (try
    (do
      (herd/custom-commands
        {:commands {"check" {:description "Check repositories."}}})
      nil)
    ([err] (string err))))
(assert (string/find ":command, :command-git, or :command-jj"
                     missing-command-message)
        "a missing command lists the valid fields")
(assert-error "a custom command needs a description"
              (herd/custom-commands
                {:commands {"check" {:command "true"}}}))
(assert-no-error "a custom command can be jj-only"
                 (herd/custom-commands
                   {:commands {"check"
                               {:command-jj "jj status"
                                :description "Check repositories."}}}))
(assert-no-error "a custom command can be Git-only"
                 (herd/custom-commands
                   {:commands {"check"
                               {:command-git "git status"
                                :description "Check repositories."}}}))
(assert-error "a custom command cannot have an unknown key"
              (herd/custom-commands
                {:commands {"check"
                            {:command-git "git status"
                             :comand-jj "jj status"
                             :description "Check repositories."}}}))
(each condition ["never" "on-failure" "always"]
  (assert-no-error (string "a custom command accepts show-output " condition)
                   (herd/custom-commands
                     {:commands {"check" {:command "true"
                                          :description "Check repositories."
                                          :show-output condition}}})))
(assert-error "a custom command show-output condition must be a string"
              (herd/custom-commands
                {:commands {"check" {:command "true"
                                     :description "Check repositories."
                                     :show-output :always}}}))
(assert-error "a custom command show-output condition must be known"
              (herd/custom-commands
                {:commands {"check" {:command "true"
                                     :description "Check repositories."
                                     :show-output "sometimes"}}}))
(assert-error "a command cannot mix common and VCS-specific forms"
              (herd/custom-commands
                {:commands {"check"
                            {:command "status"
                             :command-git "git status"
                             :command-jj "jj status"
                             :description "Check repositories."}}}))
(assert (= 6 (herd/configured-jobs {})) "six jobs is the default")
(assert (= 3 (herd/configured-jobs {:jobs 3})) "a job count can be configured")
(each invalid [0 -2 1.5 "4" :four 2147483648]
  (assert-error (string "a configured job count rejects " (describe invalid))
                (herd/configured-jobs {:jobs invalid})))
(assert-error "the job configuration must be a dictionary"
              (herd/configured-jobs []))

(let [commands
      (herd/custom-commands
        {:commands {"check" {:command "true"
                             :description "Check repositories."}}})]
  (assert (= "Check repositories." (get-in commands ["check" :help]))
          "a custom command retains its description")
  (assert (function? (get-in commands ["check" :run]))
          "a custom command provides a handler"))

(let [commands
      (herd/custom-commands
        {:commands
         {"check" {:command-git "git status"
                   :command-jj "jj status"
                   :description "Check repositories."}}})]
  (assert (function? (get-in commands ["check" :run]))
          "a VCS-specific custom command provides a handler"))

(assert (deep= {:command-git "git status" :command-jj "jj status"}
               (herd/command-from-definition
                 "check"
                 {:command-git "git status" :command-jj "jj status"}))
        "VCS-specific configuration becomes a per-repository command")
(assert (deep= {:command-jj "jj status"}
               (herd/command-from-definition
                 "check" {:command-jj "jj status"}))
        "a VCS-specific command can support only jj")

(let [dir (fixture)
      config-path (path/join dir "config.jdn")]
  (spit config-path `(error "this code must not run")`)
  (def message
    (try
      (do (herd/load-command-config config-path) nil)
      ([err] (string err))))
  (assert (and message (string/find "expected a JDN dictionary" message))
          "loading JDN parses an expression as data instead of running it")
  (sh/rm dir))

(let [dir (fixture)
      config-path (path/join dir "config.jdn")]
  (spit config-path `{:defaults {:vcs "git"}}`)
  (assert (= "git" (get-in (herd/load-command-config config-path)
                           [:settings :defaults :vcs]))
          "the default VCS is loaded from config.jdn")
  (sh/rm dir))

# --- resolve-repository-paths ---------------------------------------------

(let [entries (herd/resolve-repository-paths
                [{:path "rel" :ssh_url "u"}
                 {:path "/already/absolute" :ssh_url "u"}]
                @[{:path "/anchor"}])]
  (assert (= "/anchor/rel" ((entries 0) :path)) "a relative path joins the anchor")
  (assert (= "/already/absolute" ((entries 1) :path)) "an absolute path is left alone")
  (assert (deep= @["/anchor"] ((entries 0) :anchors))
          "resolved entries retain their configuration anchor")
  (assert (= "u" ((entries 0) :ssh_url)) "the rest of the entry survives")
  (assert (= "jj" ((entries 0) :vcs))
          "a checkout no level settles is a jj checkout"))

(let [entries (herd/resolve-repository-paths
                [{:path "plain" :ssh_url "u"}
                 {:path "own" :ssh_url "u" :vcs "jj"}]
                @[{:path "/anchor" :vcs "git"}])]
  (assert (= "git" ((entries 0) :vcs)) "an anchor settles the VCS beneath it")
  (assert (= "jj" ((entries 1) :vcs)) "an entry overrides the anchor it is under"))

(assert (empty? (herd/resolve-repository-paths
                  [{:path "rel" :ssh_url "u"}
                   {:path "/already/absolute" :ssh_url "u"}]
                  @[]))
        "entries anchored nowhere resolve to no repositories")

(let [entries (herd/resolve-repository-paths
                [{:path "rel" :ssh_url "u"}]
                @[{:path "/one"} {:path "/two"}])]
  (assert (= 2 (length entries)) "every anchor resolves the same entry once")
  (assert (deep= @["/one/rel" "/two/rel"] (map |($ :path) entries))
          "a relative path joins each anchor in turn")
  (assert (deep= @[@["/one"] @["/two"]] (map |($ :anchors) entries))
          "each resolved entry keeps the anchor it came from"))

# --- config-directory -----------------------------------------------------

(let [home (os/getenv "HOME")
      xdg (os/getenv "XDG_CONFIG_HOME")]
  (os/setenv "XDG_CONFIG_HOME" "/x")
  (assert (= "/x/herd" (herd/config-directory)) "XDG_CONFIG_HOME wins")
  (os/setenv "XDG_CONFIG_HOME" nil)
  (os/setenv "HOME" "/h")
  (assert (= "/h/.config/herd" (herd/config-directory)) "HOME is the fallback")
  (os/setenv "HOME" nil)
  (assert (nil? (herd/config-directory)) "neither set means no directory")
  (os/setenv "HOME" home)
  (os/setenv "XDG_CONFIG_HOME" xdg))

# --- discover-config-files ------------------------------------------------

(let [dir (fixture)]
  (assert (empty? (herd/discover-config-files (string dir "/missing")))
          "a missing directory holds no configuration")
  (assert (empty? (herd/discover-config-files nil)) "no directory at all holds none")
  (spit (string dir "/b.json") "[]")
  (spit (string dir "/a.json") "[]")
  (spit (string dir "/notes.txt") "ignored")
  (sh/create-dirs (string dir "/directory.json"))
  (sh/create-dirs (string dir "/root"))
  (os/link (string dir "/root") (string dir "/a.json.root") true)
  (assert (deep= (herd/discover-config-files dir)
                 @[(string dir "/a.json") (string dir "/b.json")])
          "repository JSON files are sorted without directories")
  (sh/rm dir))

# --- checkout rows --------------------------------------------------------

(assert-error "a row must be a dictionary"
              (herd/validate-checkout-row [] ":checkouts row 0"))
(assert-error "a row needs a source"
              (herd/validate-checkout-row {:anchor "work"} ":checkouts row 0"))
(assert-error "a row source must be a string"
              (herd/validate-checkout-row {:from 1} ":checkouts row 0"))
(assert-error "a row source must not be empty"
              (herd/validate-checkout-row {:from ""} ":checkouts row 0"))
(assert-error "a row anchor must be a string"
              (herd/validate-checkout-row {:from "a.json" :anchor 1}
                                          ":checkouts row 0"))
(assert-error "a row anchor must not be empty"
              (herd/validate-checkout-row {:from "a.json" :anchor ""}
                                          ":checkouts row 0"))
(assert-error "a row rejects settings it cannot carry"
              (herd/validate-checkout-row {:from "a.json" :jobs 2}
                                          ":checkouts row 0"))
(assert-error "the anchors an anchor replaced are not a row setting"
              (herd/validate-checkout-row {:from "a.json" :anchors ["work"]}
                                          ":checkouts row 0"))
(assert-error "a row VCS must be git or jj"
              (herd/validate-checkout-row {:from "a.json" :vcs "svn"}
                                          ":checkouts row 0"))
(assert-no-error "a source alone is a valid row"
                 (herd/validate-checkout-row {:from "a.json"}
                                             ":checkouts row 0"))
(assert-no-error "a row settles an anchor and a VCS"
                 (herd/validate-checkout-row
                   {:from "a.json" :anchor "/srv" :vcs "git"}
                   ":checkouts row 0"))

(let [message (error-message
                |(herd/validate-checkout-row {:unknown true}
                                             ":checkouts row 2"))]
  (assert (and message (string/find ":checkouts row 2" message))
          "a row error names the row it came from"))

(assert-error "the defaults must be a dictionary"
              (herd/validate-checkout-defaults []))
(assert-error "the defaults cannot name a source"
              (herd/validate-checkout-defaults {:from "a.json"}))
(assert-error "the defaults reject settings they cannot carry"
              (herd/validate-checkout-defaults {:jobs 2}))
(assert-error "a default anchor must not be empty"
              (herd/validate-checkout-defaults {:anchor ""}))
(assert-error "a default VCS must be git or jj"
              (herd/validate-checkout-defaults {:vcs "svn"}))
(assert-no-error "empty defaults are valid"
                 (herd/validate-checkout-defaults {}))
(assert-no-error "the defaults settle an anchor and a VCS"
                 (herd/validate-checkout-defaults {:anchor "src" :vcs "git"}))

# --- configured-repository-settings ---------------------------------------

(assert-error "the JDN configuration must be a dictionary"
              (herd/configured-repository-settings []))
(assert-error "the checkouts must be an array"
              (herd/configured-repository-settings {:checkouts {}}))
(assert-error "every row is validated"
              (herd/configured-repository-settings
                {:checkouts [{:from "work.json"} {:unknown true}]}))
(assert-error "the defaults are validated"
              (herd/configured-repository-settings {:defaults {:vcs "svn"}}))
(assert-no-error "a configuration need settle nothing"
                 (herd/configured-repository-settings {}))

(let [settings (herd/configured-repository-settings
                 {:checkouts [{:from "work.json" :anchor "work"}
                              {:from "vendor.json" :anchor "/opt"}
                              {:from "work.json" :anchor "/srv" :vcs "git"}]})]
  (assert (deep= @["work" "/srv"]
                 (map |($ :anchor) (get-in settings [:rows "work.json"])))
          "rows reading one file are grouped in the order they were written")
  (assert (= 1 (length (get-in settings [:rows "vendor.json"])))
          "each file keeps only the rows that read it"))

# --- rows-for-file --------------------------------------------------------

(let [settings (herd/configured-repository-settings
                 {:defaults {:anchor "src" :vcs "jj"}
                  :checkouts [{:from "work.json" :anchor "work"}
                              {:from "work.json" :anchor "/srv" :vcs "git"}]})
      unmentioned (herd/rows-for-file settings "other.json")
      work (herd/rows-for-file settings "work.json")]
  (assert (= 1 (length unmentioned))
          "a file no row reads is checked out once")
  (assert (= "src" ((unmentioned 0) :anchor))
          "and takes its anchor from the defaults")
  (assert (= "jj" ((unmentioned 0) :vcs))
          "along with the rest of them")
  (assert (deep= @["work" "/srv"] (map |($ :anchor) work))
          "a file its rows read is checked out once per row")
  (assert (= "jj" ((work 0) :vcs))
          "a row keeps the defaults it does not name")
  (assert (= "git" ((work 1) :vcs))
          "and replaces the ones it does"))

(let [rows (herd/rows-for-file herd/default-repository-settings "any.json")]
  (assert (= 1 (length rows)) "without a configuration every file is read once")
  (assert (nil? ((rows 0) :anchor))
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
                 (anchor-paths
                   (herd/config-anchors (string configuration "/real.json")
                                        configuration @[{}])))
          "a file in the configuration directory anchors at home")
  (assert (deep= @["/home/example"]
                 (anchor-paths
                   (herd/config-anchors (string configuration "/link.json")
                                        configuration @[{}])))
          "a JSON symlink uses its visible location")
  (assert (deep= @[(path/abspath elsewhere)]
                 (anchor-paths
                   (herd/config-anchors (string elsewhere "/linked.json")
                                        configuration @[{}])))
          "a file outside the configuration directory anchors at its parent")
  (assert (deep= @["/home/example/work"]
                 (anchor-paths
                   (herd/config-anchors (string configuration "/real.json")
                                        configuration @[{:anchor "work"}])))
          "a relative configured anchor resolves from home")
  (assert (deep= @["/home/example/work" "/srv/shared"]
                 (anchor-paths
                   (herd/config-anchors (string configuration "/real.json")
                                        configuration
                                        @[{:anchor "work"}
                                          {:anchor "/srv/shared"}])))
          "every row is resolved in the order it was written")
  (assert (deep= @[]
                 (anchor-paths
                   (herd/config-anchors (string configuration "/real.json")
                                        configuration @[])))
          "a file no row reads is anchored nowhere")
  (assert (deep= @["/missing/anchor"]
                 (anchor-paths
                   (herd/config-anchors (string configuration "/real.json")
                                        configuration
                                        @[{:anchor "/missing/anchor"}])))
          "an absolute configured anchor need not exist")

  # A row carries the checkout options it was merged with, and nothing else.
  (let [anchors (herd/config-anchors (string configuration "/real.json")
                                     configuration
                                     @[{:anchor "work" :vcs "git"}
                                       {:anchor "/srv" :vcs "jj"}])]
    (assert (deep= @["/home/example/work" "/srv"] (anchor-paths anchors))
            "each row is resolved on its own")
    (assert (= "git" ((anchors 0) :vcs)) "keeping the options it settles")
    (assert (= "jj" ((anchors 1) :vcs)) "one row at a time"))
  (let [anchors (herd/config-anchors (string configuration "/real.json")
                                     configuration @[{:anchor "work"}])]
    (assert (nil? ((anchors 0) :vcs))
            "a row settling no options carries none at all"))

  (sh/create-dirs (string elsewhere "/work"))
  (os/link elsewhere (string dir "/link") true)
  (assert (deep= @[(string dir "/link/work")]
                 (anchor-paths
                   (herd/config-anchors (string configuration "/real.json")
                                        configuration
                                        @[{:anchor (string dir "/link/work")}])))
          "a configured anchor is kept as it was written, symlinks and all")

  (os/setenv "HOME" nil)
  (assert (deep= @[(path/abspath configuration)]
                 (anchor-paths
                   (herd/config-anchors (string configuration "/real.json")
                                        configuration @[{}])))
          "the configuration directory is the default without home")
  (def message
    (config-error (string configuration "/real.json")
                  configuration @[{:anchor "work"}]))
  (assert (and message (string/find "without HOME" message))
          "a relative configured anchor needs home")
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
  (let [loaded (herd/load-config
                 [config] configuration
                 (herd/configured-repository-settings
                   {:checkouts [{:from "repos.json" :anchor "root"}]}))]
    (assert (= (string (path/abspath dir) "/root/relative")
               ((loaded 0) :path))
            "relative paths use the configured anchor")
    (assert (= "/absolute" ((loaded 1) :path))
            "absolute paths ignore the configured anchor")
    (assert (deep= @[(string (path/abspath dir) "/root")]
                   ((loaded 0) :anchors))
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
  (let [loaded (herd/load-config
                 [config] configuration
                 (herd/configured-repository-settings
                   {:checkouts [{:from "repos.json" :anchor "one"}
                                {:from "repos.json" :anchor "two"}]}))
        root (path/abspath dir)]
    (assert (= 3 (length loaded))
            "several rows check the relative tree out at each of their anchors")
    (assert (deep= @[(string root "/one/relative")
                     "/absolute"
                     (string root "/two/relative")]
                   (map |($ :path) loaded))
            "each anchor contributes its own resolved paths")
    (assert (deep= @[(string root "/one")] ((loaded 0) :anchors))
            "a relative path belongs to the anchor it resolved under")
    (assert (deep= @[(string root "/one") (string root "/two")]
                   ((loaded 1) :anchors))
            "an absolute path stays one repository under every anchor"))
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
  (let [loaded (herd/load-config
                 (herd/discover-config-files configuration) configuration
                 (herd/configured-repository-settings
                   {:defaults {:anchor "root"}
                    :checkouts [{:from "second.json" :anchor "elsewhere"}]}))
        root (path/abspath dir)]
    (assert (deep= @[(string root "/root/one") (string root "/elsewhere/two")]
                   (map |($ :path) loaded))
            "a file no row reads resolves from the defaults alone"))
  (assert-error "a row reading a file that is not there is refused"
                (herd/load-config
                  (herd/discover-config-files configuration) configuration
                  (herd/configured-repository-settings
                    {:checkouts [{:from "renamed.json" :anchor "root"}]})))
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
  (let [loaded (herd/load-config
                 [config] configuration
                 (herd/configured-repository-settings
                   {:defaults {:vcs "jj"}
                    :checkouts [{:from "repos.json" :anchor "a" :vcs "git"}
                                {:from "repos.json" :anchor "b"}]}))]
    (assert (deep= @["git" "jj" "jj" "jj"] (map |($ :vcs) loaded))
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
  (each config-path [regular broken directory]
    (write-config config-path [{:path (path/basename config-path) :ssh_url "u"}]))
  (spit (string regular ".root") "not a symlink")
  (os/link (string dir "/missing") (string broken ".root") true)
  (os/link target (string directory ".root") true)
  (os/setenv "HOME" dir)
  (let [loaded (herd/load-config (herd/discover-config-files configuration)
                                 configuration)]
    (assert (= 3 (length loaded)) "root companions do not affect loading")
    (assert (every?
              (map |(string/has-prefix? (string (path/abspath dir) "/") ($ :path))
                   loaded))
            "every root companion form is ignored"))
  (os/setenv "HOME" home)
  (sh/rm dir))

# --- read-config and load-config ------------------------------------------

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

  (let [merged (herd/load-config (herd/discover-config-files configuration) configuration)]
    (assert (deep= (map |($ :path) merged)
                   @[(string dir "/src/alpha")
                     "/opt/beta"
                     (string dir "/gamma")])
            "every file contributes from its visible configuration location"))

  # The same checkout in two files is fine while they agree on the URL.
  (write-config (string configuration "/agrees.json")
                [{:path "src/alpha" :ssh_url "git@example.com:alpha.git"}])
  (assert (= 3 (length (herd/load-config (herd/discover-config-files configuration) configuration)))
          "an agreeing duplicate is dropped")

  (write-config (string configuration "/agrees.json")
                [{:path "src/alpha" :ssh_url "git@example.com:different.git"}])
  (assert-error "a disagreeing duplicate is refused"
                (herd/load-config (herd/discover-config-files configuration) configuration))

  (assert-error "an unreadable file is refused"
                (herd/load-config [(string dir "/absent.json")] configuration))
  (os/setenv "HOME" home)
  (sh/rm dir))

(let [dir (fixture)
      first (string dir "/first/repos.json")
      second (string dir "/second/repos.json")
      checkout (string dir "/shared")]
  (write-config first [{:path checkout :ssh_url "shared-url"}])
  (write-config second [{:path checkout :ssh_url "shared-url"}])
  (let [loaded (herd/load-config [first second] nil)]
    (assert (= 1 (length loaded)) "an agreeing duplicate remains one repository")
    (assert (deep= (map path/abspath [(path/parent first) (path/parent second)])
                   ((loaded 0) :anchors))
            "an agreeing duplicate retains every configuration anchor"))
  (sh/rm dir))

(end-suite)
