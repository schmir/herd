# Comparing the configured repositories with the ones on disk.

(import spork/path)
(import ./discover)
(import ./location)
(import ./vcs)

(defn discover-root
  ``Return the directory a discovery from `at-path` starts at: the innermost
  repository holding `at-path`, or `at-path` itself. Selection picks the
  configured repositories holding the working location, so the discovery has to
  reach them too.``
  [at-path]
  (var directory (path/abspath at-path))
  (var found nil)
  (while (nil? found)
    (def parent (path/parent directory))
    (cond
      (discover/repository? directory) (set found directory)
      # path/parent of the root is the root itself, or empty.
      (or (empty? parent) (= parent directory)) (set found (path/abspath at-path))
      (set directory parent)))
  found)

(defn extra-repositories
  ``Return the repositories in `discovered` that no repository in `configured`
  names, comparing paths the way selection does. `configured` must be every
  configured repository, not the selected ones, or a repository another
  anchor or filter keeps would read as extra.``
  [discovered configured]
  (def known (tabseq [repository :in configured]
               (location/resolved-path (repository :path)) true))
  (filter (fn [repository] (not (get known (location/resolved-path (repository :path))))) discovered))

(defn remote-url
  ``Return the URL of the origin remote of a discovered repository, or nil
  when it has none or the VCS cannot say.``
  [repository]
  (vcs/remote-url (repository :vcs) (repository :path)))
