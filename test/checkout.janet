# Tests for telling what is on disk at a repository's path.
(use spork/test)
(import spork/path)
(import spork/sh)
(import ../checkout)

(start-suite "checkout")

(def dir (path/join (os/getenv "TMPDIR" "/tmp")
                    (string "herd-checkout-test-" (os/getpid))))
(sh/rm dir)

(sh/create-dirs (path/join dir "git" ".git"))
(sh/create-dirs (path/join dir "jj" ".jj"))
(sh/create-dirs (path/join dir "worktree"))
(spit (path/join dir "worktree" ".git") "gitdir: /elsewhere")
(sh/create-dirs (path/join dir "empty"))
(sh/create-dirs (path/join dir "plain"))
(spit (path/join dir "plain" "notes.txt") "no repository here")
(spit (path/join dir "file") "a file")
(os/symlink (path/join dir "nowhere") (path/join dir "dangling"))
(os/symlink (path/join dir "empty") (path/join dir "link-to-empty"))
(os/symlink (path/join dir "git") (path/join dir "link-to-git"))

(defn- status
  "Return the status of the repository at `name` below the test directory."
  [name]
  (checkout/checkout-status {:path (path/join dir name)}))

(assert (= "ok" (status "git")))
(assert (= "ok" (status "jj")))
(assert (= "ok" (status "worktree")) "a worktree names its .git as a file")
(assert (= "missing" (status "absent")) "nothing at the path is missing")
(assert (= "missing" (status "empty"))
        "an empty directory is missing, since clone fills it")
(assert (= "blocked" (status "plain"))
        "a directory holding anything but a repository is blocked")
(assert (= "blocked" (status "file")) "so is a file")
(assert (= "blocked" (status "dangling"))
        "a dangling link stands in the way although it leads nowhere")
(assert (= "missing" (status "link-to-empty"))
        "a link to an empty directory is followed, since clone fills it")
(assert (= "ok" (status "link-to-git")) "a link to a repository is followed")

(sh/rm dir)
(end-suite)
