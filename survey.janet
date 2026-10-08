# Comparing the configured repositories with the ones on disk.

(import spork/path)
(import ./discover)
(import ./process)
(import ./select)

(defn scan-root
  ``Return the directory a scan from `at` starts at: the innermost repository
  holding `at`, or `at` itself. Selection picks the configured repositories
  holding the working location, so the scan has to reach them too.``
  [at]
  (var directory (path/abspath at))
  (var found nil)
  (while (nil? found)
    (def parent (path/parent directory))
    (cond
      (discover/repository? directory) (set found directory)
      # path/parent of the root is the root itself, or empty.
      (or (empty? parent) (= parent directory)) (set found (path/abspath at))
      (set directory parent)))
  found)

(defn extra-repositories
  ``Return the repositories in `discovered` that no entry in `configured`
  names, comparing paths the way selection does. `configured` must be every
  configured repository, not the selected ones, or a repository another
  anchor or filter keeps would read as extra.``
  [discovered configured]
  (def known (tabseq [repository :in configured]
               (select/comparable-path (repository :path)) true))
  (filter (fn [repository] (not (get known (select/comparable-path (repository :path))))) discovered))

(defn- origin-from-jj
  "Return the URL of the remote named origin in `jj git remote list` output."
  [output]
  (some (fn [line]
          (def [name url] (string/split " " (string/trim line) 0 2))
          (when (and (= "origin" name) url) (string/trim url)))
        (string/split "\n" output)))

(defn remote-url
  ``Return the URL of the origin remote of a discovered repository, or nil
  when it has none or the VCS cannot say. jj is told to leave the working
  copy alone, since asking about a remote must not snapshot it.``
  [repository]
  (def root (repository :path))
  (def [program args]
    (if (= "jj" (repository :vcs))
      ["jj" ["--ignore-working-copy" "-R" root "git" "remote" "list"]]
      ["git" ["-C" root "remote" "get-url" "origin"]]))
  (when-let [executable (process/find-executable program)]
    (def result (process/capture-process [executable ;args]))
    (when (zero? (result :status))
      (def out (string (result :out)))
      (def url (if (= "jj" (repository :vcs))
                 (origin-from-jj out)
                 (string/trim out)))
      (unless (or (nil? url) (empty? url)) url))))
