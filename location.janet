# Choosing configured repositories by filesystem location.

(import spork/path)

(defn- bare-path
  "Drop trailing slashes, which normalisation keeps but comparison must not."
  [path]
  (def trimmed (string/trimr path "/"))
  (if (empty? trimmed) "/" trimmed))

(defn resolved-path
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

(defn- caching-resolved-path
  ``A function that gives the `resolved-path` of a path, asking the
  filesystem once for each distinct path it is given. A catalog has a few
  anchors that every repository repeats, and resolving each again for every
  repository is most of what a selection costs. It lasts as long as the call
  that made it, so a link that changes between runs is never remembered.``
  []
  (def known @{})
  (fn [path]
    (or (get known path)
        (let [resolved (resolved-path path)]
          (put known path resolved)
          resolved))))

(defn- holds-path?
  ``Whether `ancestor` is `descendant` or holds it somewhere below. Compares
  whole segments, so /srv/foobar is not held by /srv/foo.``
  [ancestor descendant]
  (or (= ancestor descendant)
      (string/has-prefix? (if (= "/" ancestor) ancestor (string ancestor "/"))
                          descendant)))

(defn configured-anchors
  ``Return the resolved form of every anchor the `repositories` are configured
  under, each once, in the order they are first seen.``
  [repositories]
  (def found @[])
  (def resolved-anchor (caching-resolved-path))
  (each repository repositories
    (each anchor (get repository :anchors [])
      (def candidate (resolved-anchor anchor))
      (unless (some (fn [known] (= candidate known)) found)
        (array/push found candidate))))
  found)

(defn containing-anchors
  "Return each configured anchor that contains `at-path`."
  [at-path repositories]
  (def resolved-at-path (resolved-path at-path))
  (filter (fn [anchor] (holds-path? anchor resolved-at-path))
          (configured-anchors repositories)))

(defn select-repositories-with-anchors
  ``Keep the repositories configured under one of the `selected-anchors` that
  are at `at-path`, beneath it or holding it.``
  [at-path repositories selected-anchors]
  (def resolved-at-path (resolved-path at-path))
  (def resolved-anchor (caching-resolved-path))
  (filter (fn [repository]
            (def candidate (resolved-path (repository :path)))
            (and (some (fn [repository-anchor]
                         (def normalized (resolved-anchor repository-anchor))
                         (some (fn [anchor] (= normalized anchor))
                               selected-anchors))
                       (get repository :anchors []))
                 (or (holds-path? resolved-at-path candidate)
                     (holds-path? candidate resolved-at-path))))
          repositories))
