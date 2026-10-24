# The version control systems herd works with, and how to tell which one a
# repository uses.

(import spork/path)

# In the order that decides when a directory holds more than one: jj controls
# a colocated repository, so its marker comes first.
(def- adapters
  [{:id :vcs/jj :name "jj" :marker ".jj"}
   {:id :vcs/git :name "git" :marker ".git"}])

(def default
  "The VCS used for repositories that do not select one."
  :vcs/jj)

(defn names
  "The names users write for a VCS, sorted."
  []
  (sorted (map (fn [adapter] (adapter :name)) adapters)))

(defn known?
  "Whether `name` is the name a user may write for a VCS."
  [name]
  (and (string? name) (not (nil? (index-of name (names))))))

(defn parse
  "The VCS a user's `name` stands for. Raise when it is not the name of one."
  [name]
  (def adapter (find (fn [adapter] (= name (adapter :name))) adapters))
  (unless adapter
    (error (string "unknown VCS " (describe name))))
  (adapter :id))

(defn name
  "The name users write for the VCS `id`."
  [id]
  ((find (fn [adapter] (= id (adapter :id))) adapters) :name))

(defn marker-names
  "The names of the markers, in the order that decides. A walk must not enter them."
  []
  (map (fn [adapter] (adapter :marker)) adapters))

(defn detect
  ``The VCS whose marker is in `directory`, or nil. A `.git` marker can be a
  file or a directory.``
  [directory]
  (when-let [adapter (find (fn [adapter]
                             (os/lstat (path/join directory (adapter :marker)) :mode))
                           adapters)]
    (adapter :id)))
