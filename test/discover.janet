# Tests for git and jj repository discovery.
(use spork/test)
(import spork/path)
(import spork/sh)
(import ../discover)

(start-suite "discover")

(def dir (path/join (os/getenv "TMPDIR" "/tmp")
                    (string "herd-discover-test-" (os/getpid))))
(sh/rm dir)

(def root (path/join dir "root"))
(def outside (path/join dir "outside"))

(defn- make-repository
  "Create a repository with the specified markers."
  [path & markers]
  (sh/create-dirs path)
  (each marker markers
    (sh/create-dirs (path/join path marker))))

(defn- paths
  "Return discovered paths relative to the test root."
  [repositories]
  (map |(string/replace (string root "/") "" ($ :path)) repositories))

(make-repository (path/join root "git-repo") ".git")
(make-repository (path/join root "jj-repo") ".jj")
(make-repository (path/join root "colocated") ".git" ".jj")
(make-repository (path/join root "outer") ".git")
(make-repository (path/join root "outer" "vendor" "inner") ".git")
(make-repository (path/join root "deep" "a" "b" "buried") ".jj")
(make-repository (path/join root ".hidden" "tucked") ".git")
(make-repository (path/join outside "linked") ".git")
# Do not scan a parent `.git` directory for submodule data.
(make-repository (path/join root "outer" ".git" "modules" "sub") ".git")
(sh/create-dirs (path/join root "plain"))
(spit (path/join root "plain" "notes.txt") "no repository here")
# A worktree names its .git as a file rather than a directory.
(sh/create-dirs (path/join root "worktree"))
(spit (path/join root "worktree" ".git") "gitdir: /elsewhere")
(os/symlink outside (path/join root "link"))
(sh/create-dirs (path/join root "loop"))
(os/symlink (path/join root "loop") (path/join root "loop" "self"))

(assert (= "jj" (discover/repository-vcs (path/join root "colocated")))
        "a colocated checkout reports the VCS that drives it")
(assert (= "git" (discover/repository-vcs (path/join root "worktree")))
        "a worktree is recognised by its .git file")
(assert (nil? (discover/repository-vcs (path/join root "plain")))
        "a plain directory has no VCS")
(assert (discover/repository? (path/join root "jj-repo")))
(assert (not (discover/repository? (path/join root "plain"))))

(def default-scan (discover/find-repositories root))

(assert (deep= @["colocated" "deep/a/b/buried" "git-repo" "jj-repo" "outer"
                 "worktree"]
               (paths default-scan))
        "the walk finds every repository below the root, outermost first")
(assert (deep= @[{:path (path/join root "git-repo") :vcs "git"}]
               (filter |(= "git-repo" (path/basename ($ :path))) default-scan))
        "a repository is described by an absolute path and its VCS name")
(assert (= "jj" ((first default-scan) :vcs))
        "a colocated repository is discovered as a jj repository")

(assert (deep= @[{:path (path/join root "jj-repo") :vcs "jj"}]
               (discover/find-repositories (path/join root "jj-repo")))
        "a root that is itself a repository is the only result")

(assert (deep= @["colocated" "git-repo" "jj-repo" "outer" "worktree"]
               (paths (discover/find-repositories root :max-depth 1)))
        "a depth limit stops the walk above the buried repository")
(assert (empty? (discover/find-repositories root :max-depth 0))
        "depth zero looks at the root alone")

(assert (deep= @["colocated" "deep/a/b/buried" "git-repo" "jj-repo" "outer"
                 "outer/vendor/inner" "worktree"]
               (paths (discover/find-repositories root :nested true)))
        "nested searches inside repositories, marker directories excepted")

(assert (deep= @[".hidden/tucked" "colocated" "deep/a/b/buried" "git-repo"
                 "jj-repo" "outer" "worktree"]
               (paths (discover/find-repositories root :hidden true)))
        "hidden also visits dot directories")

(assert (deep= @["colocated" "deep/a/b/buried" "git-repo" "jj-repo" "link/linked"
                 "outer" "worktree"]
               (paths (discover/find-repositories root :follow-links true)))
        "follow-links reaches repositories behind a symbolic link")

# Completion proves that the self-link did not cause a loop.
(assert (deep= @["colocated" "deep/a/b/buried" "git-repo" "jj-repo" "link/linked"
                 "outer" "outer/vendor/inner" "worktree"]
               (paths (discover/find-repositories root
                                                  :follow-links true
                                                  :nested true
                                                  :hidden false)))
        "a symbolic link back into the tree ends the walk instead of looping")

(assert-error "a file is not a tree to walk"
              (discover/find-repositories (path/join root "plain" "notes.txt")))
(assert-error "a missing root is reported rather than walked"
              (discover/find-repositories (path/join dir "absent")))
(each depth [-1 1.5 "2"]
  (assert-error (string "max-depth rejects " depth)
                (discover/find-repositories root :max-depth depth)))

(sh/rm dir)

(end-suite)
