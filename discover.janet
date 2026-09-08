(import spork/path)

(def markers
  "VCS markers in precedence order. jj controls colocated repositories."
  [["jj" ".jj"] ["git" ".git"]])

(def marker-names
  "Marker names that the walk must not enter."
  (map |($ 1) markers))

(defn repository-vcs
  ``Return the VCS marked in `directory`, or nil.
  A `.git` marker can be a file or a directory.``
  [directory]
  (some (fn [[vcs marker]]
          (when (os/lstat (path/join directory marker) :mode) vcs))
        markers))

(defn repository?
  "Whether `directory` is the root of a git or jj repository."
  [directory]
  (not (nil? (repository-vcs directory))))

(defn- require-max-depth
  "Return `max-depth`, or raise unless it is nil or a non-negative integer."
  [max-depth]
  (unless (or (nil? max-depth) (and (int? max-depth) (>= max-depth 0)))
    (error "max-depth must be nil or a non-negative integer"))
  max-depth)

(defn- child-directories
  "Return sorted child directories. Skip directories that cannot be read."
  [directory hidden follow-links]
  (def names (try (os/dir directory) ([_] @[])))
  (sort (seq [name :in names
              :when (not (index-of name marker-names))
              :when (or hidden (not (string/has-prefix? "." name)))
              :let [child (path/join directory name)
                    mode (os/lstat child :mode)]
              :when (or (= :directory mode)
                        # lstat returns the link. stat rejects broken links and
                        # targets that are not directories.
                        (and follow-links
                             (= :link mode)
                             (= :directory (os/stat child :mode))))]
          child)))

(defn find-repositories
  ``Find git and jj repositories at or below `root`, outermost first.
  Return each repository as `{:path :vcs}` with an absolute path.

  Stop at repositories unless `:nested` is set. `:hidden` includes dot
  directories. `:follow-links` follows symbolic links. `:max-depth` limits
  the walk, with `root` at depth zero.``
  [root &named max-depth hidden follow-links nested]
  (require-max-depth max-depth)
  (def start (path/abspath root))
  (unless (= :directory (os/stat start :mode))
    (error (string root " is not a directory")))
  (def found @[])
  (def visited @{})

  (defn revisited?
    "Return true if followed links revisit a directory."
    [directory]
    (when follow-links
      (def resolved (try (os/realpath directory) ([_] directory)))
      (if (get visited resolved)
        true
        (do
          (put visited resolved true)
          false))))

  # Push children in reverse to preserve sorted depth-first order.
  (def stack @[[start 0]])
  (while (not (empty? stack))
    (def [directory depth] (array/pop stack))
    (unless (revisited? directory)
      (def vcs (repository-vcs directory))
      (when vcs
        (array/push found {:path directory :vcs vcs}))
      (when (and (or nested (nil? vcs))
                 (or (nil? max-depth) (< depth max-depth)))
        (each child (reverse (child-directories directory hidden follow-links))
          (array/push stack [child (inc depth)])))))
  found)
