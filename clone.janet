# Checking out the repositories that are not checked out yet.

(import spork/path)
(import spork/sh)
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

(defn staging-path
  ``Return where a clone of `target` is written before it is moved into
  place: a hidden sibling, so the move stays on one file system.``
  [target]
  (path/join (path/dirname target)
             (string "." (path/basename target) ".herd-clone")))

(defn- clone-into-place
  ``Run the clone command `command-for` returns for a staging path beside
  path, and move the result to path once the VCS succeeds, so path only ever
  holds a finished clone. Return what capture-process did, with a failed
  move as a nonzero status.``
  [command-for env path]
  # A link to an empty directory is filled through: the clone replaces the
  # directory it leads to, and the link is kept.
  (def target (if (= :link (os/lstat path :mode)) (os/realpath path) path))
  (def staging (staging-path target))
  # What a crashed clone left behind, which the VCS would refuse to clone
  # into.
  (sh/rm staging)
  (def result (process/capture-process (command-for staging) : env))
  (if (zero? (result :status))
    (try
      (do
        # rename replaces an empty directory at target.
        (os/rename staging target)
        result)
      ([err]
        (sh/rm staging)
        (merge result {:status 1 :err (string err)})))
    (do
      (sh/rm staging)
      result)))

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
        (def result
          (clone-into-place
            |(clone-process-command (or vcs checkout/default-vcs)
                                    executable url $)
            env path))
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
