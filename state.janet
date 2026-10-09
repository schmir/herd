# Telling whether a checked-out repository holds changes nobody has committed.

(import ./checkout)
(import ./parallel)
(import ./process)

(defn state-command
  ``The command that reports whether the working copy of the repository at
  `path` has changes, for a repository using `vcs`. jj is not told to leave
  the working copy alone, since it would then miss edits it has not yet
  snapshotted.``
  [path vcs]
  (case vcs
    :git ["git" "-C" path "status" "--porcelain"]
    :jj ["jj" "-R" path "log" "-r" "@" "--no-graph" "-T" "empty"]))

(defn- has-changes?
  "Whether `output` of the state command says the working copy has changes."
  [vcs output]
  (def text (string/trim (string output)))
  (case vcs
    :git (not (empty? text))
    # The working-copy commit is empty exactly when there is nothing to commit.
    :jj (case text
          "true" false
          "false" true
          (error (string "unexpected output from jj: " (describe text))))))

(defn repository-state
  ``Say whether the repository has changes: :dirty or :clean, or nil when no
  working copy is checked out at its path. Raise when the VCS cannot say.``
  [repository]
  (when-let [vcs (checkout/repository-vcs repository)]
    (def [program & args] (state-command (repository :path) vcs))
    (def executable (process/find-executable program))
    (unless executable
      (error (string "cannot find " program " to read the state")))
    (def result (process/capture-process [executable ;args]))
    (unless (zero? (result :status))
      (error (string program " failed: " (string/trim (string (result :err))))))
    (if (has-changes? vcs (result :out)) :dirty :clean)))

(defn keep-repositories
  ``Keep the `repositories` for which `keep?` answers true, in their order.
  They are asked in parallel, and the call raises when any could not be
  answered, since a command run on a selection that is missing some
  repositories is worse than none. An interrupted run leaves the unasked
  repositories out, so the caller has to look at `parallel/interrupted?`
  before acting on the result.``
  [repositories keep? &opt jobs]
  (def kept @{})
  (def counts
    (parallel/run-repositories
      repositories
      [[:kept "kept"] [:dropped "dropped"] [:failed "failed"]]
      (fn [repository report]
        (cond
          (keep? repository) (do (put kept (repository :path) true) :kept)
          :dropped))
      jobs
      # A selection is a step towards the command, which has its own progress.
      false))
  (when (pos? (counts :failed))
    (error (string "cannot check " (counts :failed) " repositories")))
  (filter (fn [repository] (get kept (repository :path))) repositories))

(defn filter-by-state
  ``Keep the `repositories` whose state is `wanted`, :dirty or :clean. A
  repository with no working copy is neither.``
  [repositories wanted &opt jobs]
  (keep-repositories repositories
                     (fn [repository] (= wanted (repository-state repository)))
                     jobs))

(defn command-matches?
  ``Whether the shell `command` exits 0 in the repository. A repository with
  no working copy never matches, and the command is not run there. Status
  126 and 127 mean the shell could not run the command, which is a mistake
  rather than a repository that does not match, so they raise.``
  [command repository]
  (if (checkout/repository-vcs repository)
    (with [devnull (file/open "/dev/null" :r)]
      (def result
        (process/capture-process
          ["sh" "-c" `cd "$1" && shift && exec "$@"`
           "herd" (repository :path) "sh" "-c" command]
          :p {:in devnull}))
      (when (index-of (result :status) [126 127])
        (error (string "cannot run " (describe command) ": "
                       (string/trim (string (result :err))))))
      (zero? (result :status)))
    false))

(defn filter-by-commands
  ``Keep the `repositories` where every one of the shell `commands` exits 0,
  in their order. A command is not run once an earlier one has failed.``
  [repositories commands &opt jobs]
  (keep-repositories repositories
                     (fn [repository]
                       (all (fn [command] (command-matches? command repository))
                            commands))
                     jobs))
