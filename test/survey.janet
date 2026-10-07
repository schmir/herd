# Tests for comparing configured repositories with the ones on disk.
(use spork/test)
(import spork/path)
(import spork/sh)
(import ../survey)

(start-suite "survey")

(def dir (path/join (os/getenv "TMPDIR" "/tmp")
                    (string "herd-survey-test-" (os/getpid))))
(sh/rm dir)
(def root (path/join dir "root"))

(sh/create-dirs (path/join root "repo" ".git"))
(sh/create-dirs (path/join root "repo" "lib" "deep"))
(sh/create-dirs (path/join root "empty"))
(sh/create-dirs (path/join root "plain"))
(spit (path/join root "plain" "notes.txt") "no repository here")
(spit (path/join root "file") "a file")
(sh/create-dirs (path/join root "unmarked" "deep"))

(defn- status
  "Return the status of the configured repository at `name` below the root."
  [name]
  (survey/checkout-status {:path (path/join root name)}))

(assert (= "ok" (status "repo")))
(assert (= "missing" (status "absent")) "nothing at the path is missing")
(assert (= "missing" (status "empty"))
        "an empty directory is missing, since clone would fill it")
(assert (= "blocked" (status "plain")))
(assert (= "blocked" (status "file")))

(assert (= (path/join root "repo")
           (survey/scan-root (path/join root "repo" "lib" "deep")))
        "a scan from inside a repository starts at that repository")
(assert (= (path/join root "repo") (survey/scan-root (path/join root "repo"))))
(assert (= (path/join root "unmarked" "deep")
           (survey/scan-root (path/join root "unmarked" "deep")))
        "outside every repository the scan starts where it was asked to")

(def discovered
  [{:path (path/join root "repo") :vcs "git"}
   {:path (path/join root "other") :vcs "jj"}])

(assert (deep= @[{:path (path/join root "other") :vcs "jj"}]
               (survey/extra-repositories
                 discovered [{:path (path/join root "repo")}]))
        "a configured repository is not extra")
(assert (deep= @[] (survey/extra-repositories
                     discovered [{:path (string (path/join root "repo") "/")}
                                 {:path (path/join root "x" ".." "other")}]))
        "paths are compared after normalisation")

(sh/create-dirs (path/join dir "link-target"))
(os/symlink (path/join dir "link-target") (path/join root "link"))
(assert (deep= @[] (survey/extra-repositories
                     [{:path (path/join root "link") :vcs "git"}]
                     [{:path (path/join dir "link-target")}]))
        "a symbolic link names the repository it leads to")

(sh/rm dir)
(end-suite)
