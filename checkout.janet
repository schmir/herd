# The checkout a repository is given: what chooses one, and what is on disk.

(import spork/path)

(def default-vcs
  "The VCS used for repositories that do not select one."
  "jj")

(def default-checkout-options
  ``Default checkout options. Their keys define the options that each
  configuration level accepts.``
  {:vcs default-vcs})

(def checkout-keys
  "Checkout option names accepted at each configuration level."
  (keys default-checkout-options))

(defn validate-checkout-options
  ``Validate checkout options and return `options`. Use `where` and the
  format-specific `spelling` in errors.``
  [options where &opt spelling]
  (default spelling ":vcs")
  (def vcs (get options :vcs :unset))
  (unless (= :unset vcs)
    (unless (and (string? vcs) (or (= "git" vcs) (= "jj" vcs)))
      (error (string where " has an invalid " spelling
                     "; expected \"git\" or \"jj\""))))
  options)

(defn repository-vcs
  "Return the VCS identified by repository metadata, or nil."
  [repository]
  (def root (repository :path))
  (cond
    (os/lstat (path/join root ".jj") :mode) :jj
    (os/lstat (path/join root ".git") :mode) :git))

(defn- vacant?
  "Whether nothing, or an empty directory, is at `path`."
  [path]
  (cond
    # lstat, since stat reads a dangling link as nothing at all, though the
    # link itself is in the way.
    (nil? (os/lstat path :mode)) true
    # stat, so a link to an empty directory is one clone can fill.
    (= :directory (os/stat path :mode)) (empty? (os/dir path))
    false))

(defn checkout-status
  ``Say what is on disk at a repository's path: "ok" for a git or jj
  repository, "missing" for nothing or an empty directory, which is what
  clone fills, and "blocked" for anything else, which clone cannot check out
  over and the other commands must not mistake for a checkout.``
  [repository]
  (cond
    (repository-vcs repository) "ok"
    (vacant? (repository :path)) "missing"
    "blocked"))
