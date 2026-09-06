# Tests for clone outcomes after parallel runner integration.
(use spork/test)
(import spork/path)
(import spork/sh)
(import ../main :as herd)

(start-suite "clone")

(def dir (path/join (os/getenv "TMPDIR" "/tmp")
                    (string "herd-clone-test-" (os/getpid))))
(sh/rm dir)
(sh/create-dirs dir)

(def existing (path/join dir "existing"))
(sh/create-dirs existing)
(spit (path/join existing "file") "present")
(assert (= :skipped (herd/clone-repository nil nil nil existing "unused"))
        "an existing checkout does not start a process")

(assert (deep= ["git-bin" "clone" "--" "url" "checkout"]
               (herd/clone-process-command "git" "git-bin" "url" "checkout"))
        "git clone uses the native Git argument form")
(assert (deep= ["jj-bin" "git" "clone" "--colocate" "--" "url" "checkout"]
               (herd/clone-process-command "jj" "jj-bin" "url" "checkout"))
        "jj clone creates a colocated repository")

(with [devnull (file/open "/dev/null" :r)]
  (def env {:in devnull :out :pipe :err :pipe})
  (var messages @[])
  (assert (= :cloned
             (herd/clone-repository (herd/find-executable "true") env
                                    |(array/push messages (string ;$&))
                                    (path/join dir "success") "unused")))
  (assert (= 1 (length messages)) "a successful clone reports completion")
  (set messages @[])
  (assert (= :failed
             (herd/clone-repository (herd/find-executable "false") env
                                    |(array/push messages (string ;$&))
                                    (path/join dir "failure") "unused")))
  (assert (= 1 (length messages)) "a failed clone reports its path"))

(def counts
  (herd/clone-repositories [{:path existing :ssh_url "unused"}]))
(assert (= 1 (counts :skipped)) "clone-repositories keeps outcome counts")
(assert (= 0 (counts :failed)))

(sh/rm dir)

(end-suite)
