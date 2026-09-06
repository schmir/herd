# Tests for running a command in repository working directories.
(use spork/test)
(import spork/path)
(import spork/sh)
(import ../main :as herd)

(start-suite "run")

(var fixture-count 0)

(defn- fixture
  "Create a fresh empty directory for one test."
  []
  (++ fixture-count)
  (def dir (path/join (os/getenv "TMPDIR" "/tmp")
                      (string "herd-run-test-" (os/getpid) "-" fixture-count)))
  (sh/rm dir)
  (sh/create-dirs dir)
  # Resolved, since TMPDIR is reached through a symlink on some systems and
  # anchors are compared against paths that have theirs resolved.
  (os/realpath dir))

(defn- repository
  "Create a repository entry for path."
  [path]
  {:path path :ssh_url "unused"})

(let [dir (fixture)
      first (string dir "/first")
      second (string dir "/second")
      previous (os/cwd)]
  (sh/create-dirs first)
  (sh/create-dirs second)
  (spit (string first "/present") "")
  (spit (string second "/present") "")
  (def counts (herd/run-in-repositories ["touch" "command ran"]
                                        [(repository first)
                                         (repository second)]))
  (assert (= 2 (counts :succeeded))
          "successful commands report no failures")
  (assert (= 0 (counts :failed)))
  (assert (= 0 (counts :not-checked-out)))
  (assert (= :file (os/stat (string first "/command ran") :mode))
          "the command runs in the first repository")
  (assert (= :file (os/stat (string second "/command ran") :mode))
          "arguments are preserved in later repositories")
  (assert (= previous (os/cwd)) "running commands restores the working directory")
  (sh/rm dir))

(let [dir (fixture)
      git-repository (string dir "/git")
      jj-repository (string dir "/jj")]
  (sh/create-dirs (string git-repository "/.git"))
  (sh/create-dirs (string jj-repository "/.jj"))
  (def counts
    (herd/run-in-repositories
      {:command-git "touch selected-git"
       :command-jj "touch selected-jj"}
      [(repository git-repository) (repository jj-repository)]))
  (assert (= 2 (counts :succeeded))
          "VCS-specific commands run in both repository types")
  (assert (= :file (os/stat (string git-repository "/selected-git") :mode))
          "a Git repository selects command-git")
  (assert (= :file (os/stat (string jj-repository "/selected-jj") :mode))
          "a jj repository selects command-jj")
  (sh/rm dir))

(let [dir (fixture)]
  (sh/create-dirs (string dir "/.git"))
  (sh/create-dirs (string dir "/.jj"))
  (def counts
    (herd/run-in-repositories
      {:command-git "touch selected-git"
       :command-jj "touch selected-jj"}
      [(repository dir)]))
  (assert (= 1 (counts :succeeded))
          "a colocated repository runs one command")
  (assert (= :file (os/stat (string dir "/selected-jj") :mode))
          "a colocated repository selects the jj command")
  (assert (nil? (os/stat (string dir "/selected-git")))
          "a colocated repository does not select the Git command")
  (sh/rm dir))

(let [dir (fixture)]
  (sh/create-dirs (string dir "/.jj"))
  (def counts
    (herd/run-in-repositories
      {:command-git "touch selected-git"}
      [(repository dir)]))
  (assert (= 1 (counts :skipped))
          "a missing command for the repository VCS is skipped")
  (assert (= 0 (counts :failed))
          "a missing VCS-specific command is not a failure")
  (assert (nil? (os/stat (string dir "/selected-git")))
          "a skipped command does not run")
  (sh/rm dir))

(let [dir (fixture)
      first (string dir "/first")
      missing (string dir "/missing")
      last (string dir "/last")]
  (sh/create-dirs first)
  (sh/create-dirs last)
  (spit (string first "/present") "")
  (spit (string last "/present") "")
  (def counts (herd/run-in-repositories ["touch" "ran"]
                                        [(repository first)
                                         (repository missing)
                                         (repository last)]))
  (assert (= 0 (counts :failed)))
  (assert (= 1 (counts :not-checked-out))
          "an unavailable repository is not checked out")
  (assert (= 2 (counts :succeeded)))
  (assert (= :file (os/stat (string first "/ran") :mode)))
  (assert (= :file (os/stat (string last "/ran") :mode))
          "a failure does not prevent later commands")
  (sh/rm dir))

(let [dir (fixture)
      first (string dir "/first")
      second (string dir "/second")]
  (sh/create-dirs first)
  (sh/create-dirs second)
  (spit (string first "/present") "")
  (spit (string second "/present") "")
  (def counts
    (herd/run-in-repositories
      ["sh" "-c" "touch ran-before-failure; exit 7"]
      [(repository first) (repository second)]))
  (assert (= 2 (counts :failed))
          "each non-zero command counts as one failure")
  (assert (= :file (os/stat (string first "/ran-before-failure") :mode)))
  (assert (= :file (os/stat (string second "/ran-before-failure") :mode))
          "a non-zero command does not prevent later commands")
  (sh/rm dir))

(let [dir (fixture)
      repo (repository dir)
      messages @[]]
  (spit (string dir "/present") "")
  (with [devnull (file/open "/dev/null" :r)]
    (def env {:in devnull :out :pipe :err :pipe})
    (assert (= :succeeded
               (herd/run-in-repository
                 ["sh" "-c" `printf "hidden\ntext\n"; printf secret >&2`]
                 env repo |(array/push messages (string ;$&)))))
    (assert (empty? messages) "successful command output stays hidden")
    (assert (= :succeeded
               (herd/run-in-repository
                 ["sh" "-c" `printf "visible\ntext\n"; printf note >&2`]
                 env repo |(array/push messages (string ;$&)) "always")))
    (assert (= 1 (length messages)) "requested successful output is one block")
    (assert (string/find (string "✓ " dir) (messages 0)))
    (assert (string/find "| stdout\n|   visible\n|   text" (messages 0)))
    (assert (string/find "| stderr\n|   note" (messages 0)))
    (array/clear messages)
    (assert (= :succeeded
               (herd/run-in-repository
                 ["true"] env repo |(array/push messages (string ;$&))
                 "always")))
    (assert (and (= 1 (length messages))
                 (= (string "✓ " dir) (messages 0)))
            "always reports a successful command without output")
    (array/clear messages)
    (assert (= :succeeded
               (herd/run-in-repository
                 ["printf" "suppressed"] env repo
                 |(array/push messages (string ;$&)) "never")))
    (assert (empty? messages) "never hides successful command results")
    (assert (= :failed
               (herd/run-in-repository
                 ["sh" "-c" `printf "visible\nsecond line\n"; printf problem >&2; exit 7`]
                 env repo |(array/push messages (string ;$&)))))
    (assert (= 1 (length messages)) "failure output is one buffered block")
    (assert (string/find (string "✗ " dir " (exit 7)") (messages 0)))
    (assert (string/find "| stdout\n|   visible\n|   second line" (messages 0)))
    (assert (string/find "| stderr\n|   problem" (messages 0)))
    (array/clear messages)
    (assert (= :failed
               (herd/run-in-repository
                 ["false"] env repo |(array/push messages (string ;$&)) "never")))
    (assert (empty? messages) "never hides failed command results"))
  (sh/rm dir))

(let [messages @[]
      state @{:reported false}
      report |(array/push messages (string ;$&))]
  (herd/report-command-result state report "first result")
  (herd/report-command-result state report "second result")
  (assert (deep= messages @["first result" "" "second result"])
          "result blocks have one empty line between them"))

(let [dir (fixture)
      first (string dir "/first")
      second (string dir "/second")
      config (string dir "/.config/herd/repositories.json")
      home (os/getenv "HOME")
      xdg (os/getenv "XDG_CONFIG_HOME")
      root (os/realpath dir)]
  (sh/create-dirs first)
  (sh/create-dirs second)
  (sh/create-dirs-to config)
  (spit (string first "/present") "")
  (spit (string second "/present") "")
  (os/setenv "HOME" root)
  (os/setenv "XDG_CONFIG_HOME" nil)
  (spit config
        `[{"path":"first","ssh_url":"unused"},
          {"path":"second","ssh_url":"unused"}]`)
  (def loaded (herd/read-config config (herd/config-directory)))
  (assert (deep= (map |($ :path) loaded)
                 @[(string root "/first") (string root "/second")])
          "default configuration resolves under home")
  (assert (= 2 (length (herd/select-repositories-with-anchors
                         root loaded false (herd/containing-anchors root loaded))))
          "the fixture root selects both repositories")
  ((herd/make-run-command "touch fixed-command"
                          "Run the fixed test command.")
    ["fixed" "--at" root])
  (assert (= :file (os/stat (string first "/fixed-command") :mode))
          "a generated handler runs its command in the first repository")
  (assert (= :file (os/stat (string second "/fixed-command") :mode))
          "a generated handler runs its command in the second repository")
  (herd/run-command ["run" "--at" root
                     "sh" "-c" `touch -- "$1"` "herd" "-command-argument"])
  (assert (= :file (os/stat (string first "/-command-argument") :mode))
          "run accepts command options without a separator")
  (assert (= :file (os/stat (string second "/-command-argument") :mode))
          "run selects every repository under the requested path")
  (spit config
        `[{"path":"first","ssh_url":"unused"},
          {"path":"second","ssh_url":"unused"},
          {"path":"missing","ssh_url":"unused"}]`)
  (with [process
         (os/spawn [(path/join (os/cwd) "build/herd")
                    "run" "--at" root
                    "--show-output" "always" "printf" "shown"]
                   :p {:out :pipe :err :pipe})]
    (def output @"")
    (def errors @"")
    (ev/gather
      (:read (process :out) :all output)
      (:read (process :err) :all errors)
      (:wait process))
    (assert (= 0 (process :return-code)) "always run succeeds")
    (assert (string/find (string "✓ " root "/first") errors)
            "always reports a successful repository")
    (assert (string/find "| stdout\n|   shown" errors)
            "always reports successful command output")
    (assert (string/find "2 succeeded, 0 failed, 0 skipped, 1 not checked out"
                         output)
            "run reports repositories that are not checked out"))
  (os/setenv "HOME" home)
  (os/setenv "XDG_CONFIG_HOME" xdg)
  (sh/rm dir))

(end-suite)
