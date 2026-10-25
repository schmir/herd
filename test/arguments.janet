# Tests for command-line option consistency.
(use spork/test)
(import spork/path)
(import spork/sh)
(import ../src/arguments)
(import ../src/clone)
(import ../src/config)
(import ../src/discover)
(import ../src/main :as herd)

(start-suite "arguments")

# --- the fix-ups for what argparse lets through --------------------------

(def spec
  ``The kinds of option the cases below are weighed against, as argparse is
  given them: a flag, a valued option, and one that may repeat.``
  {"all-anchors" {:kind :flag :short "a"}
   "at" {:kind :option :short "C"}
   "filter" {:kind :accumulate :short "f"}
   "help" {:kind :flag :short "h"}})

(def positional-spec
  "The same, with a command's own arguments after the options."
  (merge spec {:default {:kind :accumulate :short-circuit true}}))

(defn- given-value
  "The flag that `args` hands a value, or nil."
  [args &opt options]
  (arguments/flag-given-value ["herd" ;args] (or options spec)))

(defn test-a-flag-given-a-value-is-found
  "--flag=VALUE names the flag, since argparse would drop the value."
  []
  (assert (= "all-anchors" (given-value ["--all-anchors=no"])))
  (assert (= "all-anchors" (given-value ["--all-anchors="]))
          "an empty value is still a value")
  (assert (= "help" (given-value ["--help=x"])) "help is a flag too")
  (assert (= "all-anchors" (given-value ["--at" "." "--all-anchors=no"]))
          "it is found after the options before it")
  (assert (nil? (given-value ["--all-anchors"])) "a flag given none is fine"))

(defn test-an-option-may-be-given-a-value
  "--option=VALUE is how a valued option takes its value."
  []
  (assert (nil? (given-value ["--at=/srv"])))
  (assert (nil? (given-value ["--filter=a" "--filter=b"])))
  (assert (nil? (given-value ["--unknown=x"])) "argparse reports what it does not know"))

(defn test-a-value-is-not-an-option
  "What an option takes as its value is not read as an option itself."
  []
  (assert (nil? (given-value ["--at" "--all-anchors=no"]))
          "the argument after --at is its value")
  (assert (nil? (given-value ["-C" "--all-anchors=no"]))
          "and after -C")
  (assert (nil? (given-value ["-aC" "--all-anchors=no"]))
          "and after a cluster that ends in an option taking one")
  (assert (= "all-anchors" (given-value ["-a" "--all-anchors=no"]))
          "but a flag in a cluster takes none"))

(defn test-options-end-where-argparse-stops-reading-them
  "After `--`, and after the first positional where that ends them, nothing is an option."
  []
  (assert (nil? (given-value ["--" "--all-anchors=no"])) "after --")
  (assert (= "all-anchors" (given-value ["--all-anchors=no" "--"])) "before --")
  (assert (nil? (given-value ["true" "--all-anchors=no"] positional-spec))
          "after the command herd runs")
  (assert (= "all-anchors"
             (given-value ["--all-anchors=no" "true"] positional-spec))
          "before it")
  (assert (= "all-anchors"
             (given-value ["true" "--all-anchors=no"]
                          (merge spec {:default {:kind :accumulate}})))
          "where positionals do not end the options, it is found after one"))

(defn test-the-version-is-asked-for-by-the-first-argument-alone
  "Only a first argument that is all about the version asks for it."
  []
  (defn asked [& args] (arguments/version-requested? ["herd" ;args]))
  (assert (asked "--version"))
  (assert (asked "-V"))
  (assert (asked "-VV") "a cluster of nothing but V")
  (assert (not (asked)) "no arguments")
  (assert (not (asked "-hV")) "-hV wants the help argparse prints")
  (assert (not (asked "-Vx")) "-Vx is a mistake")
  (assert (not (asked "--version=x")) "argparse is left to refuse the value")
  (assert (not (asked "--versions")))
  (assert (not (asked "list" "--version")) "a command owns its own options")
  (assert (not (asked "--" "--version")))
  (assert (not (asked "-")) "a lone hyphen is a word, not a flag")
  (assert (not (asked "")) "an empty argument is not one"))

(test-a-flag-given-a-value-is-found)
(test-an-option-may-be-given-a-value)
(test-a-value-is-not-an-option)
(test-options-end-where-argparse-stops-reading-them)
(test-the-version-is-asked-for-by-the-first-argument-alone)

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
              (string command " supports all-anchor selection"))
      (assert (string/find "-f, --filter NAME" (result :output))
              (string command " supports selection by named filter")))

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
            "help documents the version flag")

    # A flag's name is only looked for where argparse reads options: an
    # option's value and the command herd runs are passed on untouched.
    (each args [["list" "--at" "--all-anchors=no"] ["run" "true" "--help=x"]
                ["run" "-j" "1" "--" "true" "--version=x"]]
      (def result (invoke args))
      (assert (not (string/find "takes no value" (result :output)))
              (string (string/join args " ") " leaves the value alone: "
                      (result :output))))

    # A cluster asks for help only when every flag in it is one the command
    # knows; anything wrong in it, before or after the h, is a usage error.
    (each args [["list" "-h"] ["list" "-ah"] ["list" "-ha"] ["-h"]]
      (def result (invoke args))
      (assert (= 0 (result :status))
              (string (string/join args " ") " asks for help"))
      (assert (not (string/find "usage error" (result :output)))
              (string (string/join args " ") " reports no mistake")))
    (each args [["list" "-hx"] ["list" "-xh"] ["fetch" "-jh"]
                ["list" "-h" "--bogus"] ["-x" "list" "-h"]
                ["--version=oops"] ["--version="] ["--help=x"]
                ["list" "--all-anchors=no"] ["list" "-C" "/" "--help=x"]]
      (def result (invoke args))
      (assert (= 1 (result :status))
              (string (string/join args " ") " is a usage error: "
                      (result :status)))
      (assert (string/find "usage error" (result :output))
              (string (string/join args " ") " names the mistake: "
                      (result :output))))))

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
            (string command " rejects an explicit repository list")))

  (def home (os/getenv "HOME"))
  (def xdg (os/getenv "XDG_CONFIG_HOME"))
  (def root (os/realpath directory))
  (def configuration (path/join root "config/herd/repos.json"))
  (def settings-file (path/join root "config/herd/config.jdn"))
  (def anchor (path/join root "work"))
  (def repository (path/join anchor "repo"))
  (defn write-settings-file
    ``Write config.jdn with the checkout row required by these tests.
    Add `body` to the shared settings.``
    [&opt body]
    (default body "")
    (spit settings-file
          (string `{:checkouts [{:from "repos.json" :anchor "work"}]`
                  "\n " body "}")))
  (sh/create-dirs-to configuration)
  (sh/create-dirs repository)
  (sh/create-dirs (path/join repository ".git"))
  (spit configuration `[{"path": "repo", "ssh_url": "unused"}]`)
  (write-settings-file)
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
  (write-settings-file
    `:commands
     {"mark" {:command "printf marker | grep marker && touch custom-command"
              :description "Create a marker in each repository."
              :show-output "always"}}`)
  (assert (= settings-file (config/settings-file-path))
          "the JDN configuration uses the XDG configuration directory")
  (assert (get-in (config/load-settings (path/parent settings-file) herd/built-in-subcommand-names)
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
  (write-settings-file
    `:jobs 2
     :commands
     {"mark" {:command "printf marker | grep marker && touch custom-command"
              :description "Create a marker in each repository."
              :show-output "always"}}`)
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
  (write-settings-file ":jobs 0")
  (def bad-configured-jobs (invoke ["list" "--at" anchor]))
  (assert (not= 0 (bad-configured-jobs :status))
          "an invalid configured job count fails")
  (assert (string/find ":jobs must be a positive integer"
                       (bad-configured-jobs :output))
          (string "an invalid configured job count names the setting: "
                  (bad-configured-jobs :output)))
  (write-settings-file
    `:commands
     {"mark" {:command "printf marker | grep marker && touch custom-command"
              :description "Create a marker in each repository."
              :show-output "always"}}`)
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
        (string "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"${0%/*}/../git-clone-arguments\"\n"
                # A clone writes the repository it was given the path of.
                "for dest; do :; done; mkdir -p \"$dest/.git\"\n"))
  (spit fake-jj
        (string "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"${0%/*}/../jj-clone-arguments\"\n"
                # A clone writes the repository it was given the path of.
                "for dest; do :; done; mkdir -p \"$dest/.git\"\n"))
  (sh/exec-fail "chmod" "+x" fake-git)
  (sh/exec-fail "chmod" "+x" fake-jj)
  (write-settings-file `:checkout-defaults {:vcs "git"}`)
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
    (assert (= (string "clone\n--\ngit-url\n" (clone/staging-path git-repository)
                       "\n")
               received-git-arguments)
            (string "the default Git clone receives the URL and a staging path: "
                    (string/format "%j" received-git-arguments)))
    (def received-jj-arguments (string (slurp jj-clone-arguments)))
    (assert (= (string "git\nclone\n--colocate\n--\njj-url\n"
                       (clone/staging-path jj-repository) "\n")
               received-jj-arguments)
            (string "the repository jj override receives the URL and a staging "
                    "path: "
                    (string/format "%j" received-jj-arguments)))
    (assert (and (discover/repository? git-repository)
                 (discover/repository? jj-repository))
            "each clone is moved from its staging path into place"))
  (spit settings-file `{:checkouts [{:from "renamed.json" :anchor "work"}]}`)
  (def renamed (invoke ["list" "--at" anchor]))
  (assert (not= 0 (renamed :status))
          "a row reading a repository list that is not there fails")
  (assert (string/find `"renamed.json"` (renamed :output))
          "the mistake names the file the row could not read")
  # Confirm that a stale row fails after its last repository list is removed.
  (sh/rm configuration)
  (def stale (invoke ["list" "--at" anchor]))
  (assert (not= 0 (stale :status))
          "a stale row fails even when no repository list is left")
  (assert (string/find `"renamed.json"` (stale :output))
          "and is still named rather than passed over as an empty directory")
  (spit settings-file "{}")
  (def nothing-configured (invoke ["list" "--at" anchor]))
  (assert (= 0 (nothing-configured :status))
          "an empty configuration directory on its own is not an error")
  (assert (string/find "No repository lists" (nothing-configured :output))
          "and says so")
  # A binary has to be able to say which release it is even when the
  # configuration it would otherwise read cannot be loaded.
  (spit settings-file "{:checkouts")
  (def broken (invoke ["list" "--at" anchor]))
  (assert (not= 0 (broken :status)) "a malformed configuration fails")
  (each flag ["--version" "-V"]
    (def result (invoke [flag]))
    (assert (= 0 (result :status))
            (string flag " succeeds with a malformed configuration"))
    (assert (string/has-prefix? "herd " (string/trimr (result :output)))
            (string flag " reports the version rather than the configuration "
                    "mistake: " (result :output))))
  (os/setenv "HOME" home)
  (os/setenv "XDG_CONFIG_HOME" xdg)
  (sh/rm directory))

# Validated custom commands become handlers beside the built-in ones.
(assert (deep= @["clone" "completions" "list" "run"]
               (sorted herd/built-in-subcommand-names))
        "the reserved names are the built-in commands")
(let [commands (herd/custom-commands
                 (config/prepare-settings
                   {:commands
                    {"check" {:command "true" :description "Check repositories."}
                     "both" {:command-git "git status"
                             :command-jj "jj status"
                             :description "Check by VCS."}}}
                   herd/built-in-subcommand-names))]
  (assert (= "Check repositories." (get-in commands ["check" :help]))
          "a custom command retains its description")
  (assert (function? (get-in commands ["check" :run]))
          "a custom command provides a handler")
  (assert (function? (get-in commands ["both" :run]))
          "a VCS-specific custom command provides a handler")
  (each name ["diff" "fetch"]
    (assert (function? (get-in commands [name :run]))
            (string name " is a default custom command with a handler"))))

# Every option the command line parses is one that options declares, and the
# other way around, so the help, the parser and the scripts cannot drift.
(import ../src/options)
(each command ["clone" "list" "run" "completions"]
  (def spec (herd/command-spec command {"at" "." "jobs" "2" "show-output" "never"}))
  (def named (seq [i :range [0 (length spec) 2]] (spec i)))
  (assert (deep= (sorted (filter (fn [name] (not= "help" name))
                                 (map (fn [option] (option :name))
                                      (options/for-command command))))
                 (sorted named))
          (string command " parses exactly the options it declares"))
  (each option (options/for-command command)
    (unless (= "help" (option :name))
      (def parsed (get spec (+ 1 (index-of (option :name) spec))))
      (assert (= (option :kind) (parsed :kind))
              (string command " --" (option :name) " parses as it is declared"))
      (assert (= (option :help) (parsed :help))
              (string command " --" (option :name) " shows its declared help"))
      (assert (= (option :short) (parsed :short))
              (string command " --" (option :name) " keeps its declared short form")))))
(assert (= "." (get-in (struct ;(herd/command-spec "list" {"at" "."})) ["at" :default]))
        "the program's defaults reach the options they are for")
(assert (nil? (get-in (struct ;(herd/command-spec "list" {"at" "."})) ["filter" :default]))
        "and only those")

(end-suite)
