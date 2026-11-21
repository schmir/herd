# The checkout a repository is given: what chooses one, and what is on disk.

(import spork/path)
(import ./vcs)

(def url-keys
  "The names a repository list may give the URL a repository is cloned from."
  ["clone_url" "ssh_url"])

(defn url-key
  ``The key that holds the clone URL of the list entry `entry`. "clone_url"
  wins when it is set and not empty, so a list can carry both, and "ssh_url"
  is used only when it is not. A JSON null is not set. With neither set it
  is "clone_url", the key an error names.``
  [entry]
  (defn set? [value] (not (or (nil? value) (= :null value))))
  (def preferred (entry "clone_url"))
  (cond
    (and (set? preferred) (not= "" preferred)) "clone_url"
    (set? (entry "ssh_url")) "ssh_url"
    "clone_url"))

(def default-repository-options
  ``Default repository options. Their keys define the options that each
  configuration level accepts.``
  {:vcs (vcs/name vcs/default-id)})

(def option-keys
  "Repository option names accepted at each configuration level."
  (keys default-repository-options))

(defn validate-repository-options
  ``Validate repository options and return `options`. Use `where` and the
  format-specific `spelling` in errors.``
  [options where &opt spelling]
  (default spelling ":vcs")
  (def vcs-name (get options :vcs :unset))
  (unless (= :unset vcs-name)
    (unless (vcs/known? vcs-name)
      (error (string where " has an invalid " spelling "; expected "
                     (string/join (map describe (vcs/names)) " or ")))))
  options)

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
  ``Say what is on disk at a repository's path: `:ok` for a git or jj
  repository, `:missing` for nothing or an empty directory, which is what
  clone fills, and `:blocked` for anything else, which clone cannot check out
  over and the other commands must not mistake for a checkout.``
  [repository]
  (cond
    (vcs/detect (repository :path)) :ok
    (vacant? (repository :path)) :missing
    :blocked))
