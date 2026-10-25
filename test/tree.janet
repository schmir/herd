# Tests for drawing the tree of repositories.
(use spork/test)
(import ../src/tree)

(start-suite "tree")

(def- nodes
  [{:label "/srv/work/" :note " (list.json)"
    :children [{:label "api" :repository? true :children []}
               {:label "libs/" :children [{:label "core" :repository? true :children []}]}]}])

(defn test-render-separates-roots
  "A blank line sits between roots and not after the last."
  []
  (assert (deep= @["a" "" "b"]
                 (tree/render [{:label "a" :children []} {:label "b" :children []}]))))

(defn test-render-draws-branches
  "Without color, the lines are the labels with their branches."
  []
  (assert (deep= @["/srv/work/ (list.json)"
                   "├── api"
                   "└── libs/"
                   "    └── core"]
                 (tree/render nodes))))

(defn test-render-colors-only-repositories
  "With color, repositories are wrapped in escape sequences and nothing else is."
  []
  (def lines (tree/render nodes true))
  (assert (string/find "/srv/work/\e[2m (list.json)\e[0m" (lines 0)) "a note is dimmed")
  (assert (= "└── libs/" (lines 2)) "a directory is plain")
  (assert (string/find "\e[32mapi\e[0m" (lines 1)) "a repository is colored")
  (assert (string/find "\e[32mcore\e[0m" (lines 3)) "a nested repository is colored"))

(defn test-from-paths-draws-the-paths-below-their-common-directory
  "Paths are drawn from the directory that holds them all, with their statuses."
  []
  (def lines
    (tree/render (tree/from-paths [{:path "/srv/a/x" :status "ok"}
                                   {:path "/srv/a/y/z"}
                                   {:path "/srv/a/y/w" :status "missing"}])))
  (assert (deep= @["/srv/a (1 repository)"
                   "├── x (ok)"
                   "└── y/ (2 repositories)"
                   "    ├── w (missing)"
                   "    └── z"]
                 lines))
  (assert (empty? (tree/from-paths [])) "no paths draw nothing"))

(test-render-separates-roots)
(test-render-draws-branches)
(test-from-paths-draws-the-paths-below-their-common-directory)
(test-render-colors-only-repositories)

(end-suite)
