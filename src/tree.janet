# A tree view of the filesystem the configuration describes: the directories
# its repository lists are placed at, marked with the lists, and the
# repositories checked out beneath them.

(import spork/path)
(import ./config)

(defn- path-parts
  "The components of the absolute `path`."
  [path]
  (filter (fn [part] (not (empty? part))) (string/split "/" path)))

(defn- new-node
  ``A node of the filesystem trie. `:placements` holds the placements anchored
  at the directory, each as `{:source :trie}` with the trie of its own
  repositories below the directory, and `:repository?` is set where a
  repository is checked out.``
  []
  @{:children @{} :placements @[] :repository? false})

(defn- node-at
  "The node of `trie` at `parts`, made on the way."
  [trie parts]
  (var node trie)
  (each part parts
    (unless ((node :children) part)
      (put (node :children) part (new-node)))
    (set node ((node :children) part)))
  node)

(defn- describe-source
  "Name a placement's list and the options it sets."
  [placement label]
  (def notes @[])
  (when (placement :vcs)
    (array/push notes (string "vcs " (placement :vcs))))
  (unless (empty? (placement :use-filters))
    (array/push notes (string "filters " (string/join (placement :use-filters) ", "))))
  (when (pos? (placement :strip-components))
    (array/push notes (string "strip " (placement :strip-components))))
  (string label (if (empty? notes) "" (string " [" (string/join notes "; ") "]"))))

(defn- list-placements
  ``Each of the `rows` of the list `label` as `{:placement :label :repositories}`,
  where `read` returns the repositories a row places.``
  [label rows read]
  (def placements (config/resolve-checkout-rows label rows))
  (seq [[row placement] :in (map tuple rows placements)]
    {:placement placement :label label :repositories (read row)}))

(defn- filesystem-trie
  ``Arrange the anchors of `placements` into a trie, and the repositories of
  each into a trie of its own at its anchor. A repository outside its anchor
  goes into the filesystem trie itself.``
  [placements]
  (def trie (new-node))
  (each {:placement placement :label label :repositories repositories} placements
    (def anchor-parts (path-parts (placement :path)))
    (def anchor (node-at trie anchor-parts))
    (def own (new-node))
    (array/push (anchor :placements) {:source (describe-source placement label) :trie own})
    (each repository repositories
      (def parts (path-parts (repository :path)))
      (def at-anchor? (deep= (tuple ;parts) (tuple ;anchor-parts)))
      (def inside? (and (> (length parts) (length anchor-parts))
                        (deep= (tuple ;anchor-parts) (tuple ;(take (length anchor-parts) parts)))))
      # A repository at the anchor itself is the root of the placement's trie.
      (put (cond
             at-anchor? own
             inside? (node-at own (drop (length anchor-parts) parts))
             (node-at trie parts))
           :repository? true)))
  trie)

(defn- count-repositories
  ``Split the repository nodes off `nodes`. Return `[nodes left]`: `nodes`
  without them and the number removed.``
  [nodes]
  [(filter (fn [node] (not (node :repository?))) nodes)
   (length (filter (fn [node] (node :repository?)) nodes))])

(defn- annotation
  "The `parts` that are not nil, as a suffix for a label."
  [& parts]
  (def present (filter truthy? parts))
  (if (empty? present)
    ""
    (string " (" (string/join present ", ") ")")))

(defn- display
  ``The display nodes for the trie node `node` named `name`, with the
  directories that hold nothing but one more directory folded into its name.
  A directory placements are anchored at ends the fold, and is shown once for
  each placement, with that placement's repositories. What else is below it,
  such as anchors further down, goes in the entry of a lone placement, beside
  the placement's own directories of the same name, and in an entry of its
  own, with no placement, beside several.``
  [name node list?]
  (var label name)
  (var end node)
  (while (and (empty? (end :placements))
              (not (end :repository?))
              (= 1 (length (end :children)))
              (let [only (first (values (end :children)))]
                (or (not (empty? (only :children))) (not (only :repository?)))))
    (def [only-name only] (first (pairs (end :children))))
    (set label (string label "/" only-name))
    (set end only))
  (def placements (end :placements))
  (def entries
    (if (empty? placements)
      [{:note nil :tries [end]}]
      (if (= 1 (length placements))
        [{:note ((first placements) :source)
          :tries [((first placements) :trie) end]
          :anchor? (((first placements) :trie) :repository?)}]
        [;(seq [placement :in placements]
            {:note (placement :source)
             :tries [(placement :trie)]
             :anchor? ((placement :trie) :repository?)})
         ;(if (empty? (end :children)) [] [{:note nil :tries [end]}])])))
  (seq [{:note note :tries tries :anchor? anchor?} :in entries]
    # The directories of every trie of the entry, by name; one a trie shares
    # with another is shown once for each.
    (def below
      (sorted-by (fn [[name index _]] [name index])
                 (mapcat (fn [[index trie]]
                           (seq [[name child] :pairs (trie :children)] [name index child]))
                         (pairs tries))))
    (def directory? (or (pos? (length placements))
                        (not (empty? below))
                        (not (end :repository?))))
    (def anchor-repository
      (if anchor? [{:label "." :repository? true :children []}] []))
    (def shown [;anchor-repository ;(mapcat (fn [[name _ child]] (display name child list?)) below)])
    (def [others counted] (count-repositories shown))
    (def children (if list? shown others))
    (def count-note
      (when (pos? counted)
        (if (= 1 counted) "1 repository" (string counted " repositories"))))
    {:label (string label (if directory? "/" ""))
     :note (annotation note (end :status) count-note)
     :repository? (and (end :repository?) (empty? placements) (empty? children) (zero? counted))
     :children children}))

(defn- roots-of
  ``The display nodes of the filesystem `trie`, starting at the directory
  where its paths part, with the repositories listed only if `list?`. Where
  no anchor holds the paths together, each branch is a root of its own with
  `split?`, and otherwise they hang from that directory.``
  [trie list? split?]
  (var root trie)
  (def parts @[])
  (while (and (empty? (root :placements))
              (not (root :repository?))
              (= 1 (length (root :children))))
    (def [name child] (first (pairs (root :children))))
    (array/push parts name)
    (set root child))
  (def start (string "/" (string/join parts "/")))
  (def shown
    (if (and split? (empty? (root :placements)) (not (root :repository?)))
      # No anchor holds the others, so name the way down in each root instead of
      # drawing a directory that is only a parent.
      (mapcat (fn [name]
                (display (string (if (= "/" start) "" start) "/" name) ((root :children) name) list?))
              (sorted (keys (root :children))))
      (display start root list?)))
  # A root is a path to copy, so it has no closing slash, unless it is all of it.
  (map (fn [root]
         (def label (root :label))
         (if (and (> (length label) 1) (string/has-suffix? "/" label))
           (merge root {:label (string/slice label 0 -2)})
           root))
       shown))

(defn build
  ``The display nodes of the configuration in `directory` as `config` loaded
  it: the filesystem from the directory that holds every anchor down, with
  the placements marked where they are anchored. Raises on a configuration
  that cannot be read. Every directory gives the number of repositories directly in it,
  and lists them only with `list?`.``
  [directory config &opt list?]
  (def settings (config :settings))
  (def filters (settings :filters))
  (def placements
    [;(mapcat identity
              (seq [list-path :in (config/discover-repository-lists directory)
                    :let [name (path/basename list-path)]]
                (list-placements name (config/checkout-rows-for-list settings name)
                                 (fn [row] (config/read-repository-list list-path [row] filters)))))
     ;(mapcat identity
              (seq [[label row] :in (config/inline-lists settings)]
                (list-placements label [row]
                                 (fn [row] (config/read-inline-list label row filters)))))])
  (def seen @{})
  (each {:label label :repositories repositories} placements
    (each repository repositories
      (put seen (repository :path) {:source label})))
  (config/reject-nested-repositories seen)
  (roots-of (filesystem-trie placements) list? true))

(defn from-paths
  ``The display nodes of the repositories at `entries`, each `{:path :status}`
  with an absolute path and, if there is one, a status to show beside the
  repository: the filesystem from the directory that holds them all, with
  every repository listed.``
  [entries]
  (def trie (new-node))
  (each {:path path :status status} entries
    (def node (node-at trie (path-parts path)))
    (put node :repository? true)
    (when status
      (put node :status status)))
  (if (empty? entries)
    []
    (roots-of trie true false)))

(def- repository-color
  "The escape sequence that starts the color repositories are printed in."
  "\e[32m")

(def- note-color
  "The escape sequence that starts the dimmed text of the notes on a label."
  "\e[2m")

(defn render
  ``The lines that draw the display `nodes`, with box-drawing branches and a
  blank line between roots. With `color?`, the repositories are in color and
  the notes dimmed.``
  [nodes &opt color?]
  (def lines @[])
  (defn paint [node]
    (def label (node :label))
    (def note (get node :note ""))
    (string (if (and color? (node :repository?))
              (string repository-color label "\e[0m")
              label)
            (if (and color? (not (empty? note)))
              (string note-color note "\e[0m")
              note)))
  (defn walk [children prefix]
    (eachp [index child] children
      (def last? (= index (dec (length children))))
      (array/push lines (string prefix (if last? "└── " "├── ") (paint child)))
      (walk (child :children) (string prefix (if last? "    " "│   ")))))
  (eachp [index node] nodes
    (unless (zero? index)
      (array/push lines ""))
    (array/push lines (paint node))
    (walk (node :children) ""))
  lines)
