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
  dir)

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
  (def counts (herd/run-in-repositories ["touch" "command ran"]
                                        [(repository first)
                                         (repository second)]))
  (assert (= 2 (counts :succeeded))
          "successful commands report no failures")
  (assert (= 0 (counts :failed)))
  (assert (= :file (os/stat (string first "/command ran") :mode))
          "the command runs in the first repository")
  (assert (= :file (os/stat (string second "/command ran") :mode))
          "arguments are preserved in later repositories")
  (assert (= previous (os/cwd)) "running commands restores the working directory")
  (sh/rm dir))

(let [dir (fixture)
      first (string dir "/first")
      missing (string dir "/missing")
      last (string dir "/last")]
  (sh/create-dirs first)
  (sh/create-dirs last)
  (def counts (herd/run-in-repositories ["touch" "ran"]
                                        [(repository first)
                                         (repository missing)
                                         (repository last)]))
  (assert (= 1 (counts :failed))
          "an unavailable repository counts as one failure")
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
  (with [devnull (file/open "/dev/null" :r)]
    (def env {:in devnull :out :pipe :err :pipe})
    (assert (= :succeeded
               (herd/run-in-repository
                 ["sh" "-c" `printf "hidden\ntext\n"; printf secret >&2`]
                 env repo |(array/push messages (string ;$&)))))
    (assert (empty? messages) "successful command output stays hidden")
    (assert (= :failed
               (herd/run-in-repository
                 ["sh" "-c" `printf "visible\nsecond line\n"; printf problem >&2; exit 7`]
                 env repo |(array/push messages (string ;$&)))))
    (assert (= 1 (length messages)) "failure output is one buffered block")
    (assert (string/find (string "✗ " dir " (exit 7)") (messages 0)))
    (assert (string/find "| stdout\n|   visible\n|   second line" (messages 0)))
    (assert (string/find "| stderr\n|   problem" (messages 0))))
  (sh/rm dir))

(let [messages @[]
      state @{:reported false}
      report |(array/push messages (string ;$&))]
  (herd/report-command-failure state report "first failure")
  (herd/report-command-failure state report "second failure")
  (assert (deep= messages @["first failure" "" "second failure"])
          "failure blocks have one empty line between them"))

(let [dir (fixture)
      first (string dir "/first")
      second (string dir "/second")
      config (string dir "/repositories.json")
      root (os/realpath dir)]
  (sh/create-dirs first)
  (sh/create-dirs second)
  (spit config
        `[{"path":"first","ssh_url":"unused"},
          {"path":"second","ssh_url":"unused"}]`)
  (def loaded (herd/read-config config (herd/config-directory)))
  (assert (deep= (map |($ :path) loaded)
                 @[(string root "/first") (string root "/second")])
          "explicit configuration resolves under its real parent")
  (assert (= 2 (length (herd/select-repositories root loaded)))
          "the fixture root selects both repositories")
  (herd/run-command ["run" "--under" root "--config" config
                     "sh" "-c" `touch -- "$1"` "herd" "-command-argument"])
  (assert (= :file (os/stat (string first "/-command-argument") :mode))
          "run accepts command options without a separator")
  (assert (= :file (os/stat (string second "/-command-argument") :mode))
          "run selects every repository under the requested path")
  (sh/rm dir))

(end-suite)
