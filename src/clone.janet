# Checking out the repositories that are not checked out yet.

(import spork/path)
(import spork/sh)
(import ./checkout)
(import ./parallel)
(import ./process)
(import ./run)
(import ./vcs)

(defn staging-path
  ``Return where a clone of `target` is written before it is moved into
  place: a hidden sibling, so the move stays on one file system.``
  [target]
  (path/join (path/dirname target)
             (string ".herd-clone-" (path/basename target))))

(defn- clone-into-place
  ``Run the clone command `make-clone-command` returns for a staging path beside
  path, and move the result to path once the VCS succeeds, so path only ever
  holds a finished clone. Return what capture did, with a failed
  move as a nonzero status.``
  [make-clone-command path]
  # A link to an empty directory is filled through: the clone replaces the
  # directory it leads to, and the link is kept.
  (def target (if (= :link (os/lstat path :mode)) (os/realpath path) path))
  (def staging (staging-path target))
  # What a crashed clone left behind, which the VCS would refuse to clone
  # into.
  (sh/rm staging)
  (def result (process/capture (make-clone-command staging)))
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
  ``Clone a repository with `vcs-id` unless it is already checked out, or
  something that is not a repository stands in its way. What happened is
  reported as herd run reports a command, as `show-output` asks and with
  `color?` in color.
  Return :present, :blocked, :cloned, or :failed.``
  [executable report url path &opt vcs-id show-output color?]
  (def show-output (run/require-show-output (or show-output run/default-show-output)))
  (def repository {:path path})
  (case (checkout/checkout-status repository)
    :ok :present
    :blocked
    (do
      (run/report-failure repository "holds something that is not a repository"
                          report show-output color?)
      :blocked)
    (try
      (do
        (def result
          (clone-into-place
            (fn [staging]
              (vcs/clone-command (or vcs-id vcs/default)
                                 executable url staging))
            path))
        (run/report-result repository result report show-output color?)
        (if (zero? (result :status)) :cloned :failed))
      ([err]
        (run/report-failure repository err report show-output color?)
        :failed))))

(defn clone-repositories
  ``Clone repositories with their selected VCS and limit concurrent processes.
  What happened to each repository is reported on stdout, as herd run reports
  a command, as `show-output` asks and with `color?` in color. A clone that
  worked is otherwise named on a line of its own when only failures would show
  its output. Return what parallel/for-each-repository does, with the cloned,
  present, blocked, and failed counts.``
  [repositories &opt jobs show-output color?]
  (def show-output (run/require-show-output (or show-output run/default-show-output)))
  (def executables
    (tabseq [name :in (vcs/names)]
      (vcs/parse name) (process/find-executable name)))
  # Lines naming clones stay together, and a block stands apart from anything.
  (def spacing @{:last nil})
  (defn report-spaced [kind report & xs]
    (when (and (spacing :last) (or (= kind :block) (= (spacing :last) :block)))
      (report ""))
    (put spacing :last kind)
    (report ;xs))
  (parallel/for-each-repository
    repositories
    [[:cloned "cloned"]
     [:present "already checked out"]
     [:blocked "blocked"]
     [:failed "failed"]]
    (fn [repository report]
      (defn report-block [& args]
        (report-spaced :block report ;args))
      # Each checkout has its final VCS after loading.
      (def vcs-id (get repository :vcs vcs/default))
      (def executable (get executables vcs-id))
      # Only a clone needs the VCS, so a repository that will not be
      # cloned is reported as what it is rather than as a missing VCS.
      (if (or executable
              (not= :missing (checkout/checkout-status repository)))
        (let [outcome (clone-repository executable report-block
                                        (repository :clone-url)
                                        (repository :path)
                                        vcs-id
                                        show-output
                                        color?)]
          (when (and (= :cloned outcome) (= "on-failure" show-output))
            (report-spaced :line report "Clone complete: " (repository :path)))
          outcome)
        (do
          (run/report-failure repository
                              (string (vcs/name vcs-id) " was not found on PATH")
                              report-block show-output color?)
          :failed)))
    jobs
    nil
    nil
    stdout))
