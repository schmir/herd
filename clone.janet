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
  "Clone a repository with vcs unless it is already checked out.
  Return :skipped, :cloned, or :failed."
  [executable env report path url &opt vcs]
  (if (checkout/checked-out? path)
    :skipped
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
  Return the cloned, skipped, and failed counts."
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
       [:failed "failed"]]
      (fn [repository report]
        # Each checkout has its final VCS after loading.
        (def selected-vcs (get repository :vcs checkout/default-vcs))
        (def executable (get executables selected-vcs))
        (if (or executable (checkout/checked-out? (repository :path)))
          (clone-repository executable env report
                            (repository :path)
                            (repository :ssh_url)
                            selected-vcs)
          (do
            (report "Clone failed: " (repository :path) ": "
                    selected-vcs " was not found on PATH")
            :failed)))
      jobs)))
