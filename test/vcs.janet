# Tests for naming the VCS a repository uses, and finding which one it is.
(use spork/test)
(import spork/path)
(import spork/sh)
(import ../src/vcs)

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

(defn test-state-command
  "The command asking for the state is built for each VCS."
  []
  (assert (= ["git" "-C" "/r" "status" "--porcelain"]
             (vcs/state-command :vcs/git "/r")))
  (assert (= ["jj" "-R" "/r" "log" "-r" "@" "--no-graph" "-T" "empty"]
             (vcs/state-command :vcs/jj "/r"))
          "jj is not told to leave the working copy alone, so it sees every edit"))

(defn test-parse-state
  "What a state command printed says whether the working copy has changes."
  []
  (assert (= :clean (vcs/parse-state :vcs/git "")) "git prints nothing when clean")
  (assert (= :clean (vcs/parse-state :vcs/git "\n")))
  (assert (= :dirty (vcs/parse-state :vcs/git " M notes\n")))
  (assert (= :clean (vcs/parse-state :vcs/jj "true\n"))
          "the working-copy commit is empty exactly when there is nothing to commit")
  (assert (= :dirty (vcs/parse-state :vcs/jj "false")))
  (def message
    (try (do (vcs/parse-state :vcs/jj "maybe") nil) ([err] (string err))))
  (assert (and message (string/find "unexpected output from jj" message))
          "anything else jj says is refused, not guessed at"))

(defn test-remote-command
  "The command asking for the origin is built for each VCS."
  []
  (assert (= ["git" "-C" "/r" "remote" "get-url" "origin"]
             (vcs/remote-command :vcs/git "/r")))
  (assert (= ["jj" "--ignore-working-copy" "-R" "/r" "git" "remote" "list"]
             (vcs/remote-command :vcs/jj "/r"))
          "jj is told to leave the working copy alone, since asking must not snapshot it"))

(defn test-parse-remote
  "What a remote command printed names the origin, or says there is none."
  []
  (assert (= "git@example.com:a.git" (vcs/parse-remote :vcs/git "git@example.com:a.git\n")))
  (assert (nil? (vcs/parse-remote :vcs/git "")) "git prints nothing for no origin")
  (assert (= "u2" (vcs/parse-remote :vcs/jj "upstream u1\norigin u2\n"))
          "jj lists every remote, so the origin is picked out")
  (assert (nil? (vcs/parse-remote :vcs/jj "upstream u1\n")) "no origin among them")
  (assert (nil? (vcs/parse-remote :vcs/jj "")) "no remotes at all"))

(defn test-clone-command
  "The command cloning a repository is built for each VCS."
  []
  (assert (deep= ["git-bin" "clone" "--" "url" "checkout"]
                 (vcs/clone-command :vcs/git "git-bin" "url" "checkout"))
          "git clone uses the native Git argument form")
  (assert (deep= ["jj-bin" "git" "clone" "--colocate" "--" "url" "checkout"]
                 (vcs/clone-command :vcs/jj "jj-bin" "url" "checkout"))
          "jj clone creates a colocated repository")
  (assert (try (do (vcs/clone-command :vcs/svn "svn" "url" "checkout") false)
            ([err] (string/find "unsupported VCS" (string err))))
          "a VCS herd does not know cannot be cloned with"))

(defn test-command-key
  "A custom command names the commands for each VCS by these keys."
  []
  (assert (= :command-git (vcs/command-key :vcs/git)))
  (assert (= :command-jj (vcs/command-key :vcs/jj))))

(test-names-and-spellings)
(test-state-command)
(test-parse-state)
(test-remote-command)
(test-parse-remote)
(test-clone-command)
(test-command-key)
(test-parse-refuses-what-is-not-a-vcs)
(test-detect)

(sh/rm root)
(end-suite)
