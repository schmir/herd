# Tests for running a command in repository working directories.
(use spork/test)
(import spork/path)
(import spork/sh)
(import ../config)
(import ../process)
(import ../run)
(import ../select)
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
  (def counts (run/run-in-repositories ["touch" "command ran"]
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
    (run/run-in-repositories
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
    (run/run-in-repositories
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
    (run/run-in-repositories
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
  (def counts (run/run-in-repositories ["touch" "ran"]
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
    (run/run-in-repositories
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
               (run/run-in-repository
                 ["sh" "-c" `printf "hidden\ntext\n"; printf secret >&2`]
                 env repo |(array/push messages (string ;$&)))))
    (assert (empty? messages) "successful command output stays hidden")
    (assert (= :succeeded
               (run/run-in-repository
                 ["sh" "-c" `printf "visible\ntext\n"; printf note >&2`]
                 env repo |(array/push messages (string ;$&)) "always")))
    (assert (= 1 (length messages)) "requested successful output is one block")
    (assert (string/find (string "✓ " dir) (messages 0)))
    (assert (string/find "| stdout\n|   visible\n|   text" (messages 0)))
    (assert (string/find "| stderr\n|   note" (messages 0)))
    (array/clear messages)
    (assert (= :succeeded
               (run/run-in-repository
                 ["true"] env repo |(array/push messages (string ;$&))
                 "always")))
    (assert (empty? messages)
            "always stays quiet about a successful command without output")
    (array/clear messages)
    (assert (= :succeeded
               (run/run-in-repository
                 ["printf" "suppressed"] env repo
                 |(array/push messages (string ;$&)) "never")))
    (assert (empty? messages) "never hides successful command results")
    (assert (= :failed
               (run/run-in-repository
                 ["sh" "-c" `printf "visible\nsecond line\n"; printf problem >&2; exit 7`]
                 env repo |(array/push messages (string ;$&)))))
    (assert (= 1 (length messages)) "failure output is one buffered block")
    (assert (string/find (string "✗ " dir " (exit 7)") (messages 0)))
    (assert (string/find "| stdout\n|   visible\n|   second line" (messages 0)))
    (assert (string/find "| stderr\n|   problem" (messages 0)))
    (array/clear messages)
    (assert (= :failed
               (run/run-in-repository
                 ["false"] env repo |(array/push messages (string ;$&)) "never")))
    (assert (empty? messages) "never hides failed command results")
    (array/clear messages)
    (assert (= :failed
               (run/run-in-repository
                 ["false"] env repo |(array/push messages (string ;$&)))))
    (assert (and (= 1 (length messages))
                 (= (string "✗ " dir " (exit 1)") (messages 0)))
            "a failure without output still names the repository"))
  (sh/rm dir))

(let [messages @[]
      state @{:reported false}
      report |(array/push messages (string ;$&))]
  (run/report-command-result state report "first result")
  (run/report-command-result state report "second result")
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
  (def loaded (config/read-config config (config/config-directory) @[{}]))
  (assert (deep= (map |($ :path) loaded)
                 @[(string root "/first") (string root "/second")])
          "default configuration resolves under home")
  (assert (= 2 (length (select/select-repositories-with-anchors
                         root loaded false (select/containing-anchors root loaded))))
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
  (with [process
         (os/spawn [(path/join (os/cwd) "build/herd")
                    "run" "--at" root "--show-output" "always" "true"]
                   :p {:out :pipe :err :pipe})]
    (def output @"")
    (def errors @"")
    (ev/gather
      (:read (process :out) :all output)
      (:read (process :err) :all errors)
      (:wait process))
    (assert (= 0 (process :return-code)) "a silent always run succeeds")
    (assert (empty? (string errors))
            (string "always prints nothing for a command without output: "
                    errors))
    (assert (string/find "2 succeeded, 0 failed, 0 skipped, 1 not checked out"
                         output)
            "a silent run still reports its counts"))
  (os/setenv "HOME" home)
  (os/setenv "XDG_CONFIG_HOME" xdg)
  (sh/rm dir))

# Tests for capture-process, which every command runs its subprocesses through.
(let [result (process/capture-process
               ["sh" "-c" "echo to stdout; echo to stderr >&2; exit 3"] :p)]
  (assert (= 3 (result :status)) "capture-process reports the exit status")
  (assert (= "to stdout\n" (string (result :out)))
          "capture-process captures stdout")
  (assert (= "to stderr\n" (string (result :err)))
          "capture-process captures stderr"))

(let [result (process/capture-process ["sh" "-c" "exec cat"] :p
                                      {:in (file/open "/dev/null" :r)})]
  (assert (zero? (result :status)) "capture-process passes a redirected stdin")
  (assert (empty? (string (result :out)))
          "a command reading from /dev/null sees no input"))

# Both pipes are drained while the process runs. A command writing more than a
# pipe buffer holds would block forever on one that is only read afterwards,
# so this hangs rather than fails if the draining ever regresses.
(let [size 300000
      result (process/capture-process
               ["sh" "-c" (string "yes 0123456789 | head -c " size "; "
                                  "yes 9876543210 | head -c " size " >&2")]
               :p)]
  (assert (= size (length (result :out)))
          "capture-process reads stdout past the pipe buffer")
  (assert (= size (length (result :err)))
          "capture-process reads stderr past the pipe buffer"))

# Each captured process closes its pipes when it is done with them. Left to the
# garbage collector, a run over a few hundred repositories exhausts the
# descriptors the process is allowed long before it finishes.
#
# The collector is held off for the count, since it closes what it reclaims:
# under the allocation the rest of the suite does it reclaims a leaked process
# quickly enough to hide the leak, which is not a guarantee a long run has.
(let [open-descriptors (fn [] (length (os/dir "/dev/fd")))
      interval (gcinterval)]
  (defer (do (gcsetinterval interval) (gccollect))
    (gcsetinterval 0x7FFFFFFF)
    (gccollect)
    (def before (open-descriptors))
    (for _ 0 40 (process/capture-process ["true"] :p))
    (def after (open-descriptors))
    (assert (<= after (+ before 2))
            (string "capture-process leaks no descriptors: " before " open "
                    "before 40 processes, " after " after"))))

# An interrupt has to reach the built binary, not just the interpreter: the
# standalone jpm builds installs none of the interpreter's signal handling,
# which is how SIGINT came to be ignored outright.
(let [dir (fixture)
      config (string dir "/repos.json")
      root (string dir "/root")
      home (os/getenv "HOME")
      xdg (os/getenv "XDG_CONFIG_HOME")]
  (defer (do (os/setenv "HOME" home) (os/setenv "XDG_CONFIG_HOME" xdg))
    (sh/create-dirs (string dir "/config/herd"))
    (os/setenv "XDG_CONFIG_HOME" (string dir "/config"))
    (os/setenv "HOME" dir)
    (def names ["a" "b" "c" "d" "e" "f"])
    (each name names
      (sh/create-dirs (string root "/" name "/.git")))
    (spit (string dir "/config/herd/repos.json")
          (string "[" (string/join
                        (seq [name :in names]
                          (string/format `{"path":"root/%s","ssh_url":"u"}` name))
                        ",") "]"))
    (with [process
           (os/spawn [(path/join (os/cwd) "build/herd")
                      "run" "--at" root "--jobs" "1"
                      "--" "sh" "-c" "sleep 1"]
                     :p {:out :pipe :err :pipe})]
      (def output @"")
      (def errors @"")
      # Long enough that a repository is under way and the run cannot have
      # reached the last of them.
      (ev/sleep 0.6)
      (os/proc-kill process false :int)
      (ev/gather
        (:read (process :out) :all output)
        (:read (process :err) :all errors)
        (:wait process))
      (assert (= 130 (process :return-code))
              (string "an interrupted run exits 130, not "
                      (process :return-code)))
      (assert (string/find "Interrupted after" (string errors))
              (string "an interrupted run says how far it got: " errors))
      # The point of winding down rather than stopping dead: whatever was in
      # flight is finished and counted, and the rest is never begun.
      (assert (string/find "succeeded" (string output))
              (string "an interrupted run still reports its counts: " output))
      (assert (not (string/find (string (length names) " succeeded")
                                (string output)))
              (string "an interrupted run does not reach every repository: "
                      output))))
  (sh/rm dir))

# find-executable answers for the user herd runs as, which the permission
# bits alone cannot: they say whether the owner, its group or everyone else
# may run a file, never which of those we are.
(let [dir (fixture)
      path (os/getenv "PATH")]
  (defer (os/setenv "PATH" path)
    (os/setenv "PATH" dir)
    (def tool (string dir "/herd-test-tool"))
    (spit tool "#!/bin/sh\nexit 0\n")

    (os/chmod tool 8r755)
    (assert (= tool (process/find-executable "herd-test-tool"))
            "a file this user may execute is found")

    (os/chmod tool 8r644)
    (assert (nil? (process/find-executable "herd-test-tool"))
            "a file nobody may execute is passed over")

    # The bug this replaced: every one of these carries an x, so searching
    # the permission string for one accepted them all, and the spawn that
    # followed failed with a permission error instead.
    (each mode [8r611 8r601 8r610]
      (os/chmod tool mode)
      # Root may execute a file with any x bit set, whoever it belongs to.
      (when (try (do (os/execute [tool] :p) false) ([_] true))
        (assert (nil? (process/find-executable "herd-test-tool"))
                (string "mode " (string/format "%o" mode)
                        " carries an x this user cannot use"))))

    (os/chmod tool 8r755)
    (sh/rm dir))

  # A directory can carry x too, meaning it can be entered rather than run.
  (def dir2 (fixture))
  (defer (sh/rm dir2)
    (os/setenv "PATH" dir2)
    (sh/create-dirs (string dir2 "/herd-test-dir"))
    (os/chmod (string dir2 "/herd-test-dir") 8r755)
    (assert (nil? (process/find-executable "herd-test-dir"))
            "a directory is not an executable, whatever its bits")))

# The search goes on past a file it cannot run, the way execvp does, rather
# than settling for the first name that matches.
(let [early (fixture)
      late (fixture)
      path (os/getenv "PATH")]
  (defer (do (os/setenv "PATH" path) (sh/rm early) (sh/rm late))
    # The shadowing file carries an x for its group and for everyone else,
    # so the permission string alone says yes to it, and the search used to
    # stop here and hand back something that could not be run.
    (spit (string early "/herd-test-shadow") "#!/bin/sh\nexit 0\n")
    (os/chmod (string early "/herd-test-shadow") 8r611)
    (spit (string late "/herd-test-shadow") "#!/bin/sh\nexit 0\n")
    (os/chmod (string late "/herd-test-shadow") 8r755)
    (os/setenv "PATH" (string early ":" late))
    # Root may run the first one, and stopping there is then correct.
    (when (try (do (os/execute [(string early "/herd-test-shadow")] :p) false)
            ([_] true))
      (assert (= (string late "/herd-test-shadow")
                 (process/find-executable "herd-test-shadow"))
              "a file that cannot be run does not shadow one that can"))))

(end-suite)
