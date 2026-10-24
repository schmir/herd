# The version control systems herd works with: how to tell which one a
# repository uses, and what to ask each of them.

(import spork/path)
(import ./process)

# In the order that decides when a directory holds more than one: jj controls
# a colocated repository, so it comes first.
(def- ids [:vcs/jj :vcs/git])

(def default
  "The VCS used for repositories that do not select one."
  :vcs/jj)

(defn- unsupported
  "Raise for a VCS herd does not know."
  [id]
  (error (string "unsupported VCS " (describe id))))

(defn name
  "The name users write for the VCS `id`."
  [id]
  (case id
    :vcs/git "git"
    :vcs/jj "jj"
    (unsupported id)))

(defn- marker
  "The name of what a directory holds when it is a repository of the VCS `id`."
  [id]
  (case id
    :vcs/git ".git"
    :vcs/jj ".jj"
    (unsupported id)))

(defn names
  "The names users write for a VCS, sorted."
  []
  (sorted (map name ids)))

(defn known?
  "Whether `text` is the name a user may write for a VCS."
  [text]
  (and (string? text) (not (nil? (index-of text (names))))))

(defn parse
  "The VCS a user's `text` names. Raise when it is not the name of one."
  [text]
  (or (find (fn [id] (= text (name id))) ids)
      (error (string "unknown VCS " (describe text)))))

(defn marker-names
  "The names of the markers, in the order that decides. A walk must not enter them."
  []
  (map marker ids))

(defn detect
  ``The VCS whose marker is in `directory`, or nil. A `.git` marker can be a
  file or a directory.``
  [directory]
  (find (fn [id] (os/lstat (path/join directory (marker id)) :mode)) ids))

(defn command-key
  "The key of a custom command that holds its command for the VCS `id`."
  [id]
  (case id
    :vcs/git :command-git
    :vcs/jj :command-jj
    (unsupported id)))

(defn state-command
  "The command that reports whether the working copy at `path` has changes."
  [id path]
  (case id
    :vcs/git ["git" "-C" path "status" "--porcelain"]
    # jj is not told to leave the working copy alone, since it would then miss
    # edits it has not yet snapshotted.
    :vcs/jj ["jj" "-R" path "log" "-r" "@" "--no-graph" "-T" "empty"]
    (unsupported id)))

(defn parse-state
  "Say :dirty or :clean from `output` of the state command. Raise when it makes no sense."
  [id output]
  (def text (string/trim (string output)))
  (case id
    :vcs/git (if (empty? text) :clean :dirty)
    # The working-copy commit is empty exactly when there is nothing to commit.
    :vcs/jj (case text
              "true" :clean
              "false" :dirty
              (error (string "unexpected output from jj: " (describe text))))
    (unsupported id)))

(defn remote-command
  "The command that lists the remotes of the repository at `path`."
  [id path]
  (case id
    :vcs/git ["git" "-C" path "remote" "get-url" "origin"]
    # Asking about a remote must not snapshot the working copy.
    :vcs/jj ["jj" "--ignore-working-copy" "-R" path "git" "remote" "list"]
    (unsupported id)))

(defn- origin-from-jj
  "The URL of the remote named origin in `jj git remote list` output."
  [output]
  (some (fn [line]
          (def [remote url] (string/split " " (string/trim line) 0 2))
          (when (and (= "origin" remote) url) (string/trim url)))
        (string/split "\n" output)))

(defn parse-remote
  "The URL of the origin in `output` of the remote command, or nil."
  [id output]
  (case id
    :vcs/git (let [url (string/trim (string output))]
               (unless (empty? url) url))
    :vcs/jj (origin-from-jj (string output))
    (unsupported id)))

(defn clone-command
  "The command that clones `url` to `path`, run by the VCS program at `executable`."
  [id executable url path]
  (case id
    :vcs/git [executable "clone" "--" url path]
    :vcs/jj [executable "git" "clone" "--colocate" "--" url path]
    (unsupported id)))

(defn state
  ``Say whether the working copy at `path`, a repository using the VCS `id`,
  has changes: :dirty or :clean. Raise when the VCS cannot say.``
  [id path]
  (def [program & args] (state-command id path))
  (def executable (process/find-executable program))
  (unless executable
    (error (string "cannot find " program " to read the state")))
  (def result (process/capture [executable ;args]))
  (unless (zero? (result :status))
    (error (string program " failed: " (string/trim (string (result :err))))))
  (parse-state id (result :out)))

(defn remote-url
  ``The URL of the origin of the repository at `path`, which uses the VCS `id`,
  or nil when it has none or the VCS cannot say.``
  [id path]
  (def [program & args] (remote-command id path))
  (when-let [executable (process/find-executable program)]
    (def result (process/capture [executable ;args]))
    (when (zero? (result :status))
      (def url (parse-remote id (result :out)))
      (unless (or (nil? url) (empty? url)) url))))
