# Tests for reading, validating and merging configuration files.
(use spork/test)
(import spork/sh)
(import ../main :as herd)

(start-suite "config")

(var fixture-count 0)

(defn- fixture
  ``A fresh empty directory for one test to scribble in. Named after the
  process so parallel runs cannot collide.``
  []
  (++ fixture-count)
  (def dir (string (os/getenv "TMPDIR" "/tmp")
                   "/herd-test-" (os/getpid) "-" fixture-count))
  (sh/rm dir)
  (sh/create-dirs dir)
  dir)

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

# --- validate-config ------------------------------------------------------

(assert-error "a bare object is not a configuration"
              (herd/validate-config {:path "a" :ssh_url "b"}))
(assert-error "entries must be objects" (herd/validate-config [42]))
(assert-error "path is required" (herd/validate-config [{:ssh_url "b"}]))
(assert-error "ssh_url is required" (herd/validate-config [{:path "a"}]))
(assert-error "path must be a string" (herd/validate-config [{:path 1 :ssh_url "b"}]))
(assert-no-error "a well formed entry passes"
                 (herd/validate-config [{:path "a" :ssh_url "b"}]))
(assert-no-error "an empty configuration is valid" (herd/validate-config []))

# --- absolute-paths -------------------------------------------------------

(let [entries (herd/absolute-paths [{:path "rel" :ssh_url "u"}
                                    {:path "/already/absolute" :ssh_url "u"}]
                                   "/anchor")]
  (assert (= "/anchor/rel" ((entries 0) :path)) "a relative path joins the anchor")
  (assert (= "/already/absolute" ((entries 1) :path)) "an absolute path is left alone")
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

# --- config-files ---------------------------------------------------------

(let [dir (fixture)]
  (assert (empty? (herd/config-files (string dir "/missing")))
          "a missing directory holds no configuration")
  (assert (empty? (herd/config-files nil)) "no directory at all holds none")
  (spit (string dir "/b.json") "[]")
  (spit (string dir "/a.json") "[]")
  (spit (string dir "/notes.txt") "ignored")
  (sh/create-dirs (string dir "/directory.json"))
  (assert (deep= (herd/config-files dir)
                 @[(string dir "/a.json") (string dir "/b.json")])
          "only .json files, sorted, and never a directory")
  (sh/rm dir))

# --- config-anchor --------------------------------------------------------

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
  (assert (= "/home/example"
             (herd/config-anchor (string configuration "/real.json") configuration))
          "a file in the configuration directory anchors at home")
  (assert (= (os/realpath elsewhere)
             (herd/config-anchor (string configuration "/link.json") configuration))
          "a symlink anchors where the file really is")
  (assert (= (os/realpath elsewhere)
             (herd/config-anchor (string elsewhere "/linked.json") configuration))
          "a file outside anchors at its own directory")
  (assert (= (os/realpath elsewhere)
             (herd/config-anchor (string elsewhere "/linked.json") nil))
          "no configuration directory still anchors at the parent")
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

  (let [merged (herd/load-config (herd/config-files configuration) configuration)]
    (assert (deep= (map |($ :path) merged)
                   @[(string dir "/src/alpha")
                     "/opt/beta"
                     (string (os/realpath elsewhere) "/gamma")])
            "every file contributes, anchored where it really lives"))

  # The same checkout in two files is fine while they agree on the URL.
  (write-config (string configuration "/agrees.json")
              [{:path "src/alpha" :ssh_url "git@example.com:alpha.git"}])
  (assert (= 3 (length (herd/load-config (herd/config-files configuration) configuration)))
          "an agreeing duplicate is dropped")

  (write-config (string configuration "/agrees.json")
              [{:path "src/alpha" :ssh_url "git@example.com:different.git"}])
  (assert-error "a disagreeing duplicate is refused"
                (herd/load-config (herd/config-files configuration) configuration))

  (assert-error "an unreadable file is refused"
                (herd/load-config [(string dir "/absent.json")] configuration))
  (os/setenv "HOME" home)
  (sh/rm dir))

(end-suite)
