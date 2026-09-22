# Choosing the configured repositories a command acts on, by location.

(import spork/path)

(defn- bare-path
  ``Drop trailing slashes, which normalisation keeps but comparison must not.``
  [path]
  (def trimmed (string/trimr path "/"))
  (if (empty? trimmed) "/" trimmed))

(defn- comparable-path
  ``Absolute `path` with the symlinks resolved in as much of it as exists.
  Selection weighs configured paths against a working directory, which the
  system already gave us resolved, so both sides have to name the same
  location the same way. A repository that is not checked out yet keeps the
  part that does not exist, which is why the whole path cannot just be
  resolved at once.``
  [path]
  (var head (bare-path (path/abspath path)))
  (def missing @[])
  (while (and (not= "/" head) (nil? (os/lstat head :mode)))
    (array/push missing (path/basename head))
    (set head (bare-path (path/parent head))))
  (def resolved (bare-path (try (os/realpath head) ([_] head))))
  (if (empty? missing)
    resolved
    (bare-path (path/join resolved ;(reverse missing)))))

(defn- holds-path?
  ``Whether `ancestor` is `descendant` or holds it somewhere below. Compares
  whole segments, so /srv/foobar is not held by /srv/foo.``
  [ancestor descendant]
  (or (= ancestor descendant)
      (string/has-prefix? (if (= "/" ancestor) ancestor (string ancestor "/"))
                          descendant)))

(defn containing-anchors
  "Return each configured anchor that contains path."
  [path repositories]
  (def root (comparable-path path))
  (def found @[])
  (each repository repositories
    (each anchor (get repository :anchors [])
      (def candidate (comparable-path anchor))
      (when (and (holds-path? candidate root)
                 (not (some |(= candidate $) found)))
        (array/push found candidate))))
  found)

(defn select-repositories-with-anchors
  "Filter repositories with anchors that were already selected."
  [path repositories all-anchors anchors]
  (def root (comparable-path path))
  (filter (fn [repository]
            (def candidate (comparable-path (repository :path)))
            (and (or all-anchors
                     (some (fn [repository-anchor]
                             (def normalized (comparable-path repository-anchor))
                             (some |(= normalized $) anchors))
                           (get repository :anchors [])))
                 (or (holds-path? root candidate)
                     (holds-path? candidate root))))
          repositories))
