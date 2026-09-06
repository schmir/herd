# Tests for command-line option consistency.
(use spork/test)
(import spork/path)
(import spork/sh)
(import ../main :as herd)

(start-suite "arguments")

(def executable (path/join (os/cwd) "build/herd"))

(defn- invoke
  "Run herd with arguments and return its status and output."
  [args]
  (with [process (os/spawn [executable ;args] :p {:out :pipe :err :pipe})]
    (def stdout @"")
    (def stderr @"")
    (ev/gather
      (:read (process :out) :all stdout)
      (:read (process :err) :all stderr)
      (:wait process))
    {:status (process :return-code) :output (string stdout stderr)}))

(each command ["clone" "fetch" "list" "run"]
  (def result (invoke [command "--help"]))
  (assert (= 0 (result :status))
          (string command " help succeeds"))
  (assert (string/find "-C, --at" (result :output))
          (string command " supports working-location selection"))
  (assert (string/find "-a, --all-anchors" (result :output))
          (string command " supports all-anchor selection")))

(assert (string/find "Fetch Git remotes" ((invoke ["fetch" "--help"]) :output))
        "fetch help describes its operation")

(let [directory (path/join (os/getenv "TMPDIR" "/tmp")
                           (string "herd-arguments-test-" (os/getpid)))
      config (path/join directory "repos.json")]
  (sh/rm directory)
  (sh/create-dirs directory)
  (spit config (string/format `[{"path": %j, "ssh_url": "unused"}]` directory))
  (each command ["clone" "list"]
    (assert (not= 0 ((invoke [command "--at" directory config]) :status))
            (string command " rejects an explicit configuration file")))

  (def home (os/getenv "HOME"))
  (def xdg (os/getenv "XDG_CONFIG_HOME"))
  (def root (os/realpath directory))
  (def configuration (path/join root "config/herd/repos.json"))
  (def metadata (path/join root "config/herd/repos.meta.json"))
  (def command-config (path/join root "config/herd/config.jdn"))
  (def anchor (path/join root "work"))
  (def repository (path/join anchor "repo"))
  (sh/create-dirs-to configuration)
  (sh/create-dirs repository)
  (spit (path/join repository "present") "")
  (spit configuration `[{"path": "repo", "ssh_url": "unused"}]`)
  (spit metadata `{"anchor": "work"}`)
  (os/setenv "HOME" root)
  (os/setenv "XDG_CONFIG_HOME" (path/join root "config"))
  (def no-anchor (invoke ["list" "--at" "/unconfigured-herd-test"]))
  (assert (= 0 (no-anchor :status)) "an empty selection is not an error")
  (assert (string/find "-a/--all-anchors" (no-anchor :output))
          "a missing anchor suggests all-anchor selection")
  (def no-repository (invoke ["list" "--at" (path/join root "other")]))
  (assert (= 0 (no-repository :status)) "an empty anchor is not an error")
  (assert (string/find "-a/--all-anchors" (no-repository :output))
          "an empty anchor suggests all-anchor selection")
  (spit command-config
        `{:commands
          {"mark" {:command "printf marker | grep -q marker && touch custom-command"
                   :description "Create a marker in each repository."}}}`)
  (assert (= command-config (herd/command-config-path))
          "the JDN configuration uses the XDG configuration directory")
  (assert (get (herd/load-custom-commands command-config) "mark")
          "the JDN configuration loads a custom command")
  (def top-help (invoke ["--help"]))
  (assert (= 0 (top-help :status))
          (string "help accepts a valid JDN configuration: " (top-help :output)))
  (assert (string/find "mark" (top-help :output))
          (string "top-level help lists a custom command: " (top-help :output)))
  (def command-help (invoke ["mark" "--help"]))
  (assert (string/find "Create a marker" (command-help :output))
          (string "custom command help uses its configured description: "
                  (command-help :output)))
  (def command-result (invoke ["mark" "--at" anchor]))
  (assert (= 0 (command-result :status))
          (string "a custom shell command succeeds: " (command-result :output)))
  (assert (= :file (os/stat (path/join repository "custom-command") :mode))
          "a custom shell command runs in the selected repository")
  (os/link anchor (path/join root "alias") true)
  (def aliased (invoke ["list" "--at" (path/join root "alias")]))
  (assert (string/find repository (aliased :output))
          (string "a working location reached through a symlink selects the "
                  "same repositories: " (aliased :output)))
  (spit (path/join root "config/herd/orphan.meta.json") "{}")
  (def orphan (invoke ["list" "--at" anchor]))
  (assert (not= 0 (orphan :status)) "orphan metadata fails repository discovery")
  (assert (string/find "has no matching orphan.json" (orphan :output))
          "an orphan metadata error names its missing source")
  (os/setenv "HOME" home)
  (os/setenv "XDG_CONFIG_HOME" xdg)
  (sh/rm directory))

(end-suite)
