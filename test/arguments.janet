# Tests for command-line option consistency.
(use spork/test)
(import spork/path)
(import spork/sh)

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

(each command ["clone" "list" "run"]
  (def result (invoke [command "--help"]))
  (assert (= 0 (result :status))
          (string command " help succeeds"))
  (assert (string/find "-C, --at" (result :output))
          (string command " supports working-location selection"))
  (assert (string/find "-a, --all-anchors" (result :output))
          (string command " supports all-anchor selection")))

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
  (sh/create-dirs-to configuration)
  (spit configuration `[{"path": "repo", "ssh_url": "unused"}]`)
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
  (os/setenv "HOME" home)
  (os/setenv "XDG_CONFIG_HOME" xdg)
  (sh/rm directory))

(end-suite)
