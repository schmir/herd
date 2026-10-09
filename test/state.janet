# Tests for telling a repository's working copy state.
(use spork/test)
(import spork/path)
(import spork/sh)
(import ../state)

(start-suite "state")

(def dir (path/join (os/getenv "TMPDIR" "/tmp")
                    (string "herd-state-test-" (os/getpid))))
(sh/rm dir)
(sh/create-dirs dir)

(defn- git
  "Run git in `directory`, failing the test when it fails."
  [directory & args]
  (def env (merge (os/environ)
                  @{"GIT_CONFIG_GLOBAL" "/dev/null"
                    "GIT_AUTHOR_NAME" "test" "GIT_AUTHOR_EMAIL" "t@example.com"
                    "GIT_COMMITTER_NAME" "test" "GIT_COMMITTER_EMAIL" "t@example.com"}))
  (assert (zero? (os/execute ["git" "-C" directory ;args] :pe env))
          (string "git " (string/join args " ") " succeeds")))

(defn- make-repository
  "Create a Git repository with one commit at `name` in the test directory."
  [name]
  (def path (path/join dir name))
  (sh/create-dirs path)
  (git path "init" "-q")
  (git path "commit" "-q" "--allow-empty" "-m" "init")
  {:path path})

(defn test-state-command
  "The command asking for the state is built for each VCS."
  []
  (assert (= ["git" "-C" "/r" "status" "--porcelain"]
             (state/state-command "/r" :git)))
  (assert (= ["jj" "-R" "/r" "log" "-r" "@" "--no-graph" "-T" "empty"]
             (state/state-command "/r" :jj))))

(defn test-repository-state
  "A repository is clean, or dirty with a modified or an untracked file."
  []
  (def repository (make-repository "one"))
  (assert (= :clean (state/repository-state repository)) "a new repository is clean")
  (spit (path/join (repository :path) "notes") "text")
  (assert (= :dirty (state/repository-state repository)) "an untracked file is a change")
  (git (repository :path) "add" "notes")
  (git (repository :path) "commit" "-q" "-m" "notes")
  (assert (= :clean (state/repository-state repository)) "committing cleans it")
  (spit (path/join (repository :path) "notes") "changed")
  (assert (= :dirty (state/repository-state repository)) "a modified file is a change"))

(defn test-no-working-copy-has-no-state
  "A path with nothing to ask has no state."
  []
  (assert (nil? (state/repository-state {:path (path/join dir "absent")}))
          "a missing path has none")
  (sh/create-dirs (path/join dir "empty"))
  (assert (nil? (state/repository-state {:path (path/join dir "empty")}))
          "an empty directory has none"))

(defn test-filter-by-state
  "Repositories are kept in their order, and only those in the wanted state."
  []
  (def repositories (map make-repository ["a" "b" "c" "d"]))
  (spit (path/join ((repositories 1) :path) "x") "x")
  (spit (path/join ((repositories 3) :path) "x") "x")
  (def missing {:path (path/join dir "absent")})
  (def all [;repositories missing])
  (assert (deep= (map (fn [r] (r :path)) [(repositories 1) (repositories 3)])
                 (map (fn [r] (r :path)) (state/filter-by-state all :dirty)))
          "dirty keeps the changed ones in order")
  (assert (deep= (map (fn [r] (r :path)) [(repositories 0) (repositories 2)])
                 (map (fn [r] (r :path)) (state/filter-by-state all :clean)))
          "clean keeps the unchanged ones, and not the missing one"))

(defn test-filter-by-state-raises-when-unreadable
  "A repository whose state cannot be read stops the selection."
  []
  (def broken (make-repository "broken"))
  (spit (path/join (broken :path) ".git" "HEAD") "garbage")
  (assert (try (do (state/filter-by-state [broken] :dirty) false) ([_] true))
          "an unreadable repository raises"))

(defn test-command-matches
  "A command matches by its exit status, run inside the repository."
  []
  (def repository (make-repository "where"))
  (assert (state/command-matches? "true" repository) "exit 0 matches")
  (assert (not (state/command-matches? "false" repository)) "exit 1 does not")
  (assert (not (state/command-matches? "test -f marker" repository))
          "the file is not there yet")
  (spit (path/join (repository :path) "marker") "")
  (assert (state/command-matches? "test -f marker" repository)
          "the command runs in the repository")
  (assert (not (state/command-matches? "true" {:path (path/join dir "absent")}))
          "a missing path never matches, and runs nothing")
  (assert (try (do (state/command-matches? "no-such-command-here" repository) false)
            ([_] true))
          "a command the shell cannot find raises"))

(defn test-filter-by-commands
  "Every command must hold, and the order of the repositories is kept."
  []
  (def repositories (map make-repository ["w1" "w2" "w3"]))
  (spit (path/join ((repositories 0) :path) "a") "")
  (spit (path/join ((repositories 0) :path) "b") "")
  (spit (path/join ((repositories 2) :path) "a") "")
  (def paths (fn [rs] (map (fn [r] (r :path)) rs)))
  (assert (deep= (paths [(repositories 0) (repositories 2)])
                 (paths (state/filter-by-commands repositories ["test -f a"])))
          "one command keeps those that pass it")
  (assert (deep= (paths [(repositories 0)])
                 (paths (state/filter-by-commands repositories ["test -f a" "test -f b"])))
          "all commands must pass"))

(test-state-command)
(test-command-matches)
(test-filter-by-commands)
(test-repository-state)
(test-no-working-copy-has-no-state)
(test-filter-by-state)
(test-filter-by-state-raises-when-unreadable)

(sh/rm dir)
(end-suite)
