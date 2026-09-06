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
  [config-path directory metadata]
  (try
    (do (herd/config-anchor config-path directory metadata) nil)
    ([err] (string err))))

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
(assert-error "a command cannot mix common and VCS-specific forms"
              (herd/custom-commands
                {:commands {"check"
                            {:command "status"
                             :command-git "git status"
                             :command-jj "jj status"
                             :description "Check repositories."}}}))
(assert (= "jj" (herd/configured-vcs {})) "jj is the default VCS")
(assert (= "git" (herd/configured-vcs {:vcs "git"}))
        "git can be selected as the VCS")
(assert (= "jj" (herd/configured-vcs {:vcs "jj"}))
        "jj can be selected explicitly")
(assert-error "the VCS must be git or jj"
              (herd/configured-vcs {:vcs "svn"}))
(assert-error "the VCS must be a string"
              (herd/configured-vcs {:vcs :git}))

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
  (spit config-path `{:vcs "git"}`)
  (assert (= "git" ((herd/load-command-config config-path) :vcs))
          "the VCS is loaded from config.jdn")
  (sh/rm dir))

# --- resolve-repository-paths ---------------------------------------------

(let [entries (herd/resolve-repository-paths
                [{:path "rel" :ssh_url "u"}
                 {:path "/already/absolute" :ssh_url "u"}]
                "/anchor")]
  (assert (= "/anchor/rel" ((entries 0) :path)) "a relative path joins the anchor")
  (assert (= "/already/absolute" ((entries 1) :path)) "an absolute path is left alone")
  (assert (deep= @["/anchor"] ((entries 0) :anchors))
          "resolved entries retain their configuration anchor")
  (assert (= "u" ((entries 0) :ssh_url)) "the rest of the entry survives"))

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
  (spit (string dir "/a.meta.json") "{}")
  (spit (string dir "/notes.txt") "ignored")
  (sh/create-dirs (string dir "/directory.json"))
  (sh/create-dirs (string dir "/root"))
  (os/link (string dir "/root") (string dir "/a.json.root") true)
  (assert (deep= (herd/discover-config-files dir)
                 @[(string dir "/a.json") (string dir "/b.json")])
          "repository JSON files are sorted without metadata or directories")
  (spit (string dir "/orphan.meta.json") "{}")
  (assert-error "orphan metadata is rejected" (herd/discover-config-files dir))
  (sh/rm (string dir "/orphan.meta.json"))
  (os/link (string dir "/missing") (string dir "/orphan.meta.json") true)
  (assert-error "orphan metadata is rejected even when it dangles"
                (herd/discover-config-files dir))
  (sh/rm dir))

# --- metadata -------------------------------------------------------------

(assert (= "/config/work.meta.json"
           (herd/metadata-path "/config/work.json"))
        "metadata replaces the JSON suffix")
(assert (= "work.json" (herd/metadata-source-name "work.meta.json"))
        "metadata names its matching JSON source")
(assert-error "metadata must be an object" (herd/validate-metadata []))
(assert-error "metadata anchors must be strings"
              (herd/validate-metadata {:anchor 1}))
(assert-error "metadata anchors must not be empty"
              (herd/validate-metadata {:anchor ""}))
(assert-error "unknown metadata settings are rejected"
              (herd/validate-metadata {:unknown true}))
(assert-no-error "an empty metadata object is valid"
                 (herd/validate-metadata {}))
(assert-no-error "an anchor is valid metadata"
                 (herd/validate-metadata {:anchor "work"}))

(let [dir (fixture)
      config (string dir "/repos.json")
      sidecar (herd/metadata-path config)]
  (write-config config [])
  (assert (deep= {} (herd/load-metadata config))
          "a missing sidecar yields empty metadata")
  (spit sidecar "[]")
  (def message
    (try
      (do (herd/load-metadata config) nil)
      ([err] (string err))))
  (assert (and message (string/find (path/basename sidecar) message))
          "invalid metadata errors name the sidecar")
  (spit sidecar "{")
  (assert-error "malformed metadata JSON is rejected"
                (herd/load-metadata config))
  (sh/rm dir))

(let [dir (fixture)
      config (string dir "/repos.json")]
  (write-config config [])
  (sh/create-dirs (herd/metadata-path config))
  (assert-error "a metadata directory is rejected"
                (herd/load-metadata config))
  (sh/rm dir))

(let [dir (fixture)
      config (string dir "/repos.json")
      sidecar (herd/metadata-path config)]
  (write-config config [])
  (os/link (string dir "/missing") sidecar true)
  (def message
    (try
      (do (herd/load-metadata config) nil)
      ([err] (string err))))
  (assert (and message (string/find (path/basename sidecar) message))
          "a metadata symlink to nothing is reported, not read as absent")
  (sh/rm dir))

# A sidecar mistake is reported by whoever knows which configuration it
# belongs to, so neither name is repeated.
(let [dir (fixture)
      config (string dir "/repos.json")
      sidecar (herd/metadata-path config)]
  (write-config config [])
  (spit sidecar `{"unknown": true}`)
  (def message
    (try
      (do (herd/load-config [config] dir) nil)
      ([err] (string err))))
  (assert (= (string config ": " (path/basename sidecar)
                     ": unknown setting unknown")
             message)
          (string "a sidecar error names the configuration and the sidecar "
                  "once each: " message))
  (sh/rm dir))

# --- config-anchor --------------------------------------------------------

(let [dir (fixture)
      configuration (string dir "/config/herd")
      elsewhere (string dir "/elsewhere")
      sidecar-target (string elsewhere "/metadata.json")
      home (os/getenv "HOME")]
  (sh/create-dirs configuration)
  (sh/create-dirs elsewhere)
  (spit (string configuration "/real.json") "[]")
  (spit (string elsewhere "/linked.json") "[]")
  (os/link (string elsewhere "/linked.json") (string configuration "/link.json") true)
  (spit sidecar-target `{"anchor":"linked"}`)
  (os/link sidecar-target (string configuration "/real.meta.json") true)

  (os/setenv "HOME" "/home/example")
  (assert (= "/home/example"
             (herd/config-anchor (string configuration "/real.json")
                                 configuration {}))
          "a file in the configuration directory anchors at home")
  (assert (= "/home/example"
             (herd/config-anchor (string configuration "/link.json")
                                 configuration {}))
          "a JSON symlink uses its visible location")
  (assert (= "/home/example/linked"
             (herd/config-anchor (string configuration "/real.json")
                                 configuration
                                 (herd/load-metadata
                                   (string configuration "/real.json"))))
          "a metadata symlink is read without using its target location")
  (assert (= (path/abspath elsewhere)
             (herd/config-anchor (string elsewhere "/linked.json")
                                 configuration {}))
          "a file outside the configuration directory anchors at its parent")
  (assert (= "/home/example/work"
             (herd/config-anchor (string configuration "/real.json")
                                 configuration {:anchor "work"}))
          "a relative configured anchor resolves from home")
  (assert (= "/missing/anchor"
             (herd/config-anchor (string configuration "/real.json")
                                 configuration {:anchor "/missing/anchor"}))
          "an absolute configured anchor need not exist")
  (sh/create-dirs (string elsewhere "/work"))
  (os/link elsewhere (string dir "/link") true)
  (assert (= (string dir "/link/work")
             (herd/config-anchor (string configuration "/real.json")
                                 configuration
                                 {:anchor (string dir "/link/work")}))
          "a configured anchor is kept as it was written, symlinks and all")

  (os/setenv "HOME" nil)
  (assert (= (path/abspath configuration)
             (herd/config-anchor (string configuration "/real.json")
                                 configuration {}))
          "the configuration directory is the default without home")
  (def message
    (config-error (string configuration "/real.json")
                  configuration {:anchor "work"}))
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
  (spit (herd/metadata-path config) `{"anchor":"root"}`)
  (os/setenv "HOME" dir)
  (let [loaded (herd/load-config [config] configuration)]
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
