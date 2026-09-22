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

(defn checked-out?
  "Check whether path already holds a checkout."
  [path]
  (and (= :directory (os/stat path :mode))
       (not (empty? (os/dir path)))))

(defn repository-vcs
  "Return the VCS identified by repository metadata, or nil."
  [repository]
  (def root (repository :path))
  (cond
    (os/lstat (path/join root ".jj") :mode) :jj
    (os/lstat (path/join root ".git") :mode) :git))
