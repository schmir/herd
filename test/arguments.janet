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

(let [xdg (os/getenv "XDG_CONFIG_HOME")
      isolated (path/join (os/getenv "TMPDIR" "/tmp")
                          (string "herd-help-test-" (os/getpid)))]
  (defer (os/setenv "XDG_CONFIG_HOME" xdg)
    (os/setenv "XDG_CONFIG_HOME" isolated)
    (each command ["clone" "fetch" "list" "run"]
      (def result (invoke [command "--help"]))
      (assert (= 0 (result :status))
              (string command " help succeeds"))
      (assert (string/find "-C, --at" (result :output))
              (string command " supports working-location selection"))
      (assert (string/find "-a, --all-anchors" (result :output))
              (string command " supports all-anchor selection")))

    (each command ["clone" "fetch" "run"]
      (assert (string/find "-j, --jobs N=6" ((invoke [command "--help"]) :output))
              (string command " documents its default job count")))

    (assert (string/find "Fetch Git remotes" ((invoke ["fetch" "--help"]) :output))
            "fetch help describes its operation")
    (each command ["fetch" "run"]
      (def output ((invoke [command "--help"]) :output))
      (assert (string/find "--show-output WHEN=on-failure" output)
              (string command " documents its default output condition")))

    # The binary was compiled with whatever HERD_VERSION the build saw, which
    # is not this test's environment, so the shape of the answer is what can
    # be checked here.
    (def result (invoke ["--version"]))
    (assert (= 0 (result :status)) "--version succeeds")
    (def reported (string/trimr (result :output)))
    (assert (string/has-prefix? "herd " reported)
            (string "--version names the program: " reported))
    (assert (not (empty? (string/slice reported 5)))
            (string "--version names a version: " reported))
    (assert (= reported (string/trimr ((invoke ["-V"]) :output)))
            "-V is the short form of --version")
    (assert (string/find "-V, --version" ((invoke ["--help"]) :output))
            "help documents the version flag")))

# The version is baked in while this file is compiled, so an unset
# HERD_VERSION has to leave something usable behind rather than nil.
(assert (and (string? herd/version) (not (empty? herd/version)))
        "a build always knows a version")

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
                   :description "Create a marker in each repository."
                   :show-output "always"}}}`)
  (assert (= command-config (herd/command-config-path))
          "the JDN configuration uses the XDG configuration directory")
  (assert (get-in (herd/load-command-config command-config)
                  [:commands "mark"])
          "the JDN configuration loads a custom command")
  (def top-help (invoke ["--help"]))
  (assert (= 0 (top-help :status))
          (string "help accepts a valid JDN configuration: " (top-help :output)))
  (assert (string/find "mark" (top-help :output))
          (string "top-level help lists a custom command: " (top-help :output)))
  (def no-command (invoke []))
  (assert (not= 0 (no-command :status)) "naming no command is a usage error")
  (each fragment ["manage multiple git/jj repositories" "Commands:" "mark"
                  "-h, --help"]
    (assert (string/find fragment (no-command :output))
            (string "the bare invocation shows the full help: " fragment)))
  (assert (= (top-help :output) (no-command :output))
          "the bare invocation prints exactly what --help prints")
  (def unknown-command (invoke ["bogus"]))
  (assert (not= 0 (unknown-command :status)) "an unknown command is an error")
  (assert (string/find `Unknown command "bogus"` (unknown-command :output))
          "an unknown command is named rather than shown the whole help")
  (def command-help (invoke ["mark" "--help"]))
  (assert (string/find "Create a marker" (command-help :output))
          (string "custom command help uses its configured description: "
                  (command-help :output)))
  (assert (string/find "--show-output WHEN=always" (command-help :output))
          "custom command help shows its configured output default")
  (def command-result (invoke ["mark" "--at" anchor]))
  (assert (= 0 (command-result :status))
          (string "a custom shell command succeeds: " (command-result :output)))
  (assert (= :file (os/stat (path/join repository "custom-command") :mode))
          "a custom shell command runs in the selected repository")
  (assert (string/find (string "✓ " repository) (command-result :output))
          "a custom command uses its configured output condition")
  (def quiet-command
    (invoke ["mark" "--at" anchor "--show-output" "never"]))
  (assert (not (string/find (string "✓ " repository) (quiet-command :output)))
          "a command-line output condition overrides the configured default")
  (def limited-jobs (invoke ["mark" "--at" anchor "--jobs" "1"]))
  (assert (= 0 (limited-jobs :status))
          (string "a job limit runs the selected repositories: "
                  (limited-jobs :output)))
  (assert (string/find (string "✓ " repository) (limited-jobs :output))
          "a job limit does not change the reported results")
  (each invalid ["0" "-2" "many" "1.5" "2147483648" "1e18"]
    (def result (invoke ["run" "--jobs" invalid "true"]))
    (assert (not= 0 (result :status))
            (string "--jobs " invalid " fails"))
    (assert (string/find "Invalid --jobs: expected a positive integer"
                         (result :output))
            (string "--jobs " invalid " explains the expected value")))
  (spit command-config
        `{:jobs 2
          :commands
          {"mark" {:command "printf marker | grep -q marker && touch custom-command"
                   :description "Create a marker in each repository."
                   :show-output "always"}}}`)
  (each command ["clone" "fetch" "run" "mark"]
    (assert (string/find "-j, --jobs N=2" ((invoke [command "--help"]) :output))
            (string command " help shows the configured job count")))
  (assert (string/find "-j, --jobs N=2"
                       ((invoke ["run" "--jobs" "5" "--help"]) :output))
          "the command line does not change the documented default")
  (def configured-jobs-run (invoke ["mark" "--at" anchor]))
  (assert (= 0 (configured-jobs-run :status))
          (string "a configured job count runs the selected repositories: "
                  (configured-jobs-run :output)))
  (assert (= 0 ((invoke ["mark" "--at" anchor "--jobs" "1"]) :status))
          "the command line overrides the configured job count")
  (assert (string/find "Invalid --jobs"
                       ((invoke ["mark" "--at" anchor "--jobs" "0"]) :output))
          "an invalid command-line count still fails with a message")
  (spit command-config `{:jobs 0}`)
  (def bad-configured-jobs (invoke ["list" "--at" anchor]))
  (assert (not= 0 (bad-configured-jobs :status))
          "an invalid configured job count fails")
  (assert (string/find ":jobs must be a positive integer"
                       (bad-configured-jobs :output))
          (string "an invalid configured job count names the setting: "
                  (bad-configured-jobs :output)))
  (spit command-config
        `{:commands
          {"mark" {:command "printf marker | grep -q marker && touch custom-command"
                   :description "Create a marker in each repository."
                   :show-output "always"}}}`)
  (def invalid-show-output
    (invoke ["run" "--show-output" "sometimes" "true"]))
  (assert (not= 0 (invalid-show-output :status))
          "an unknown command-line output condition fails")
  (assert (string/find "expected \"never\", \"on-failure\", or \"always\""
                       (invalid-show-output :output))
          "an invalid output condition lists the valid values")
  (os/link anchor (path/join root "alias") true)
  (def aliased (invoke ["list" "--at" (path/join root "alias")]))
  (assert (string/find repository (aliased :output))
          (string "a working location reached through a symlink selects the "
                  "same repositories: " (aliased :output)))
  (def original-path (os/getenv "PATH"))
  (def bin (path/join root "bin"))
  (def fake-git (path/join bin "git"))
  (def fake-jj (path/join bin "jj"))
  (def git-clone-arguments (path/join root "git-clone-arguments"))
  (def jj-clone-arguments (path/join root "jj-clone-arguments"))
  (def git-repository (path/join anchor "git-repo"))
  (def jj-repository (path/join anchor "jj-repo"))
  (sh/create-dirs bin)
  (spit fake-git
        "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"${0%/*}/../git-clone-arguments\"\n")
  (spit fake-jj
        "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"${0%/*}/../jj-clone-arguments\"\n")
  (sh/exec-fail "chmod" "+x" fake-git)
  (sh/exec-fail "chmod" "+x" fake-jj)
  (spit command-config `{:vcs "git"}`)
  (sh/rm repository)
  (spit configuration
        `[{"path":"git-repo","ssh_url":"git-url"},
          {"path":"jj-repo","ssh_url":"jj-url","vcs":"jj"}]`)
  (defer (os/setenv "PATH" original-path)
    (os/setenv "PATH" (string bin ":" original-path))
    (def clone-result (invoke ["clone" "--at" anchor]))
    (assert (= 0 (clone-result :status))
            (string "clone supports mixed Git and jj repositories: "
                    (clone-result :output)))
    (def received-git-arguments (string (slurp git-clone-arguments)))
    (assert (= (string "clone\n--\ngit-url\n" git-repository "\n")
               received-git-arguments)
            (string "the default Git clone receives the URL and path: "
                    (string/format "%j" received-git-arguments)))
    (def received-jj-arguments (string (slurp jj-clone-arguments)))
    (assert (= (string "git\nclone\n--colocate\n--\njj-url\n"
                       jj-repository "\n")
               received-jj-arguments)
            (string "the repository jj override receives the URL and path: "
                    (string/format "%j" received-jj-arguments))))
  (spit (path/join root "config/herd/orphan.meta.json") "{}")
  (def orphan (invoke ["list" "--at" anchor]))
  (assert (not= 0 (orphan :status)) "orphan metadata fails repository discovery")
  (assert (string/find "has no matching orphan.json" (orphan :output))
          "an orphan metadata error names its missing source")
  (os/setenv "HOME" home)
  (os/setenv "XDG_CONFIG_HOME" xdg)
  (sh/rm directory))

(end-suite)
