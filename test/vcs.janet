# Tests for naming the VCS a repository uses, and finding which one it is.
(use spork/test)
(import spork/path)
(import spork/sh)
(import ../vcs)

(start-suite "vcs")

(defn test-names-and-spellings
  "A VCS is the keyword herd uses and the name its users write."
  []
  (assert (deep= @["git" "jj"] (vcs/names)) "the names users may write")
  (assert (= :vcs/git (vcs/parse "git")) "a name becomes its keyword")
  (assert (= :vcs/jj (vcs/parse "jj")))
  (assert (= "git" (vcs/name :vcs/git)) "and a keyword its name")
  (assert (= "jj" (vcs/name :vcs/jj)))
  (assert (and (vcs/known? "git") (vcs/known? "jj")) "both names are known")
  (assert (not (or (vcs/known? "svn") (vcs/known? :jj) (vcs/known? nil)
                   (vcs/known? :vcs/git)))
          "anything else is not, a keyword included")
  (assert (= :vcs/jj vcs/default) "a repository that selects none uses jj")
  (assert (deep= @[".jj" ".git"] (vcs/marker-names))
          "the markers come in the order that decides, jj first"))

(defn test-parse-refuses-what-is-not-a-vcs
  "A name that is not known raises, rather than becoming a keyword."
  []
  (assert (try (do (vcs/parse "svn") false) ([_] true))))

(def root (path/join (os/getenv "TMPDIR" "/tmp") (string "herd-vcs-test-" (os/getpid))))
(sh/rm root)
(sh/create-dirs root)

(defn- directory
  "Make the directory `name` under the root, holding the `markers` given."
  [name & markers]
  (def dir (path/join root name))
  (sh/create-dirs dir)
  (each marker markers
    (def full (path/join dir marker))
    (if (string/has-suffix? "/" marker)
      (sh/create-dirs full)
      (spit full "gitdir: elsewhere")))
  dir)

(defn test-detect
  "The marker in a directory says which VCS it holds, and jj wins over git."
  []
  (assert (= :vcs/jj (vcs/detect (directory "colocated" ".jj/" ".git/")))
          "a colocated repository is a jj one")
  (assert (= :vcs/jj (vcs/detect (directory "jj-only" ".jj/"))))
  (assert (= :vcs/git (vcs/detect (directory "git-only" ".git/"))))
  (assert (= :vcs/git (vcs/detect (directory "worktree" ".git")))
          "a .git file marks a worktree")
  (assert (nil? (vcs/detect (directory "plain"))) "no marker, no VCS")
  (assert (nil? (vcs/detect (path/join root "absent"))) "nor does nothing at all"))

(test-names-and-spellings)
(test-parse-refuses-what-is-not-a-vcs)
(test-detect)

(sh/rm root)
(end-suite)
