# Telling whether a checked-out repository holds changes nobody has committed.

(import ./vcs)
(import ./parallel)
(import ./process)

(defn repository-state
  ``Say whether the repository has changes: :dirty or :clean, or nil when no
  working copy is checked out at its path. Raise when the VCS cannot say.``
  [repository]
  (when-let [used (vcs/detect (repository :path))]
    (vcs/state used (repository :path))))

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
  [repository command]
  (if (vcs/detect (repository :path))
    (let [result (process/capture-process
                   ["sh" "-c" `cd "$1" && shift && exec "$@"`
                    "herd" (repository :path) "sh" "-c" command]
                   :p)]
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
                       (all (fn [command] (command-matches? repository command))
                            commands))
                     jobs))
