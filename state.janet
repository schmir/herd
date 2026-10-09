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

(defn filter-by-state
  ``Keep the `repositories` whose state is `wanted`, :dirty or :clean, in
  their order. A repository with no working copy is neither. The states are
  read in parallel, and raise when any could not be read, since a command
  run on a selection that is missing some repositories is worse than none.
  An interrupted run leaves unread repositories out, so the caller has to
  look at `parallel/interrupted?` before acting on the result.``
  [repositories wanted &opt jobs]
  (def states @{})
  (def counts
    (parallel/run-repositories
      repositories
      [[:kept "kept"] [:dropped "dropped"] [:failed "failed"]]
      (fn [repository report]
        (def state (repository-state repository))
        (put states (repository :path) state)
        (if (= wanted state) :kept :dropped))
      jobs))
  (when (pos? (counts :failed))
    (error (string "cannot tell the state of " (counts :failed) " repositories")))
  (filter (fn [repository] (= wanted (get states (repository :path))))
          repositories))
