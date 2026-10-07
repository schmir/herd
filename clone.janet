# Checking out the repositories that are not checked out yet.

(import ./parallel)
(import ./process)
(import ./checkout)

(defn clone-process-command
  "Return the process command that clones url to path with vcs."
  [vcs executable url path]
  (case vcs
    "git" [executable "clone" "--" url path]
    "jj" [executable "git" "clone" "--colocate" "--" url path]
    (error (string "unsupported VCS " vcs))))

(defn clone-repository
  ``Clone a repository with vcs unless it is already checked out, or
  something that is not a repository stands in its way.
  Return :skipped, :blocked, :cloned, or :failed.``
  [executable env report path url &opt vcs]
  (case (checkout/checkout-status {:path path})
    "ok" :skipped
    "blocked"
    (do
      (report "Clone blocked: " path
              " holds something that is not a repository")
      :blocked)
    (try
      (do
        (def command (clone-process-command (or vcs checkout/default-vcs)
                                            executable url path))
        (def result (process/capture-process command : env))
        (if (zero? (result :status))
          (do
            (report "Clone complete: " path)
            :cloned)
          (do
            (report "Clone failed: " path)
            (when (pos? (length (result :err))) (report (result :err)))
            (when (pos? (length (result :out))) (report (result :out)))
            :failed)))
      ([err]
        (report "Clone failed: " path ": " err)
        :failed))))

(defn clone-repositories
  "Clone repositories with their selected VCS and limit concurrent processes.
  Return the cloned, skipped, blocked, and failed counts."
  [repositories &opt jobs]
  (def executables {"git" (process/find-executable "git")
                    "jj" (process/find-executable "jj")})
  # Clones must never inherit the terminal: several run at once, and a VCS
  # or SSH prompt on a shared stdin would interleave or hang the whole run.
  (with [devnull (file/open "/dev/null" :r)]
    (def env {:in devnull})
    (parallel/run-repositories
      repositories
      [[:cloned "cloned"]
       [:skipped "already checked out"]
       [:blocked "blocked"]
       [:failed "failed"]]
      (fn [repository report]
        # Each checkout has its final VCS after loading.
        (def selected-vcs (get repository :vcs checkout/default-vcs))
        (def executable (get executables selected-vcs))
        # Only a clone needs the VCS, so a repository that will not be
        # cloned is reported as what it is rather than as a missing VCS.
        (if (or executable
                (not= "missing" (checkout/checkout-status repository)))
          (clone-repository executable env report
                            (repository :path)
                            (repository :ssh_url)
                            selected-vcs)
          (do
            (report "Clone failed: " (repository :path) ": "
                    selected-vcs " was not found on PATH")
            :failed)))
      jobs)))
