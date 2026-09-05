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
(assert (= :skipped (herd/checkout nil nil nil existing "unused"))
        "an existing checkout does not start a process")

(with [devnull (file/open "/dev/null" :r)]
  (def env {:in devnull :out :pipe :err :pipe})
  (var messages @[])
  (assert (= :cloned
             (herd/checkout (herd/find-executable "true") env
                            |(array/push messages (string ;$&))
                            (path/join dir "success") "unused")))
  (assert (= 1 (length messages)) "a successful clone reports completion")
  (set messages @[])
  (assert (= :failed
             (herd/checkout (herd/find-executable "false") env
                            |(array/push messages (string ;$&))
                            (path/join dir "failure") "unused")))
  (assert (= 1 (length messages)) "a failed clone reports its path"))

(def counts
  (herd/checkout-all [{:path existing :ssh_url "unused"}]))
(assert (= 1 (counts :skipped)) "checkout-all keeps clone outcome counts")
(assert (= 0 (counts :failed)))

(sh/rm dir)

(end-suite)
