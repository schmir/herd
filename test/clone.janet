# Tests for clone outcomes after parallel runner integration.
(use spork/test)
(import spork/path)
(import spork/sh)
(import ../src/checkout)
(import ../src/clone)
(import ../src/process)

(start-suite "clone")

(assert (= "/a/.herd-clone-b" (clone/staging-path "/a/b"))
        "a clone is staged in a hidden sibling")
(assert (= "/a/.herd-clone-.b" (clone/staging-path "/a/.b"))
        "a hidden target does not share the staging path of its unhidden namesake")

(def dir (path/join (os/getenv "TMPDIR" "/tmp")
                    (string "herd-clone-test-" (os/getpid))))
(sh/rm dir)
(sh/create-dirs dir)

(def existing (path/join dir "existing"))
(sh/create-dirs (path/join existing ".git"))
(assert (= :present (clone/clone-repository nil nil "unused" existing))
        "an existing checkout does not start a process")

(def occupied (path/join dir "occupied"))
(sh/create-dirs occupied)
(spit (path/join occupied "file") "present")
(var blocked-messages @[])
(assert (= :blocked (clone/clone-repository nil
                                            (fn [& args] (array/push blocked-messages (string ;args)))
                                            "unused" occupied))
        "something that is not a repository blocks the clone")
(assert (deep= @[(string "✗ " occupied
                         "\n! holds something that is not a repository")]
               blocked-messages)
        "a blocked clone is reported as a failed command is")

(defn fake-vcs
  ``Write an executable at `name` in the test directory that runs `body` as
  sh, with the clone path, the last argument, in $dest. Return its path.``
  [name body]
  (def script (path/join dir name))
  (spit script (string "#!/bin/sh\nfor dest; do :; done\n" body "\n"))
  (os/chmod script 8r755)
  script)

# Writes the marker first, as a real clone does.
(def cloning-vcs (fake-vcs "cloning" `mkdir -p "$dest/.git"`))
# Writes the marker, then dies as a crashed or killed clone would.
(def dying-vcs (fake-vcs "dying" `mkdir -p "$dest/.git"; exit 9`))

(do
  (var messages @[])
  (def success (path/join dir "success"))
  (assert (= :cloned
             (clone/clone-repository cloning-vcs
                                     (fn [& args] (array/push messages (string ;args)))
                                     "unused" success)))
  (assert (empty? messages) "a successful clone stays quiet by default")
  (assert (= :directory (os/stat (path/join success ".git") :mode))
          "a successful clone is moved into place")
  (assert (nil? (os/lstat (clone/staging-path success)))
          "a successful clone leaves no staging directory")

  (def hidden-target (path/join dir ".hidden-target"))
  (assert (= :cloned (clone/clone-repository cloning-vcs (fn [&]) "unused"
                                             hidden-target))
          "a hidden target is cloned")
  (assert (= :directory (os/stat (path/join hidden-target ".git") :mode)))

  (def empty (path/join dir "empty"))
  (sh/create-dirs empty)
  (assert (= :cloned (clone/clone-repository cloning-vcs (fn [&]) "unused"
                                             empty))
          "an empty directory is cloned into")
  (assert (= :directory (os/stat (path/join empty ".git") :mode)))

  (def link-target (path/join dir "link-target"))
  (def link (path/join dir "link"))
  (sh/create-dirs link-target)
  (os/symlink "link-target" link)
  (assert (= :cloned (clone/clone-repository cloning-vcs (fn [&]) "unused"
                                             link))
          "a link to an empty directory is cloned through")
  (assert (= :link (os/lstat link :mode)) "the link is kept")
  (assert (= :directory (os/stat (path/join link-target ".git") :mode)))

  (def leftover (path/join dir "leftover"))
  (sh/create-dirs (path/join (clone/staging-path leftover) ".git"))
  (assert (= :cloned (clone/clone-repository cloning-vcs (fn [&]) "unused"
                                             leftover))
          "what an earlier crashed clone staged does not stop the next one")

  (set messages @[])
  (def failure (path/join dir "failure"))
  (assert (= :failed
             (clone/clone-repository (process/find-executable "false")
                                     (fn [& args] (array/push messages (string ;args)))
                                     "unused" failure)))
  (assert (deep= @[(string "✗ " failure " (exit 1)")] messages)
          "a failed clone is headed by its path and exit status")

  (def crashed (path/join dir "crashed"))
  (assert (= :failed (clone/clone-repository dying-vcs (fn [&]) "unused"
                                             crashed)))
  (assert (= :missing (checkout/checkout-status {:path crashed}))
          "a clone that dies half-written does not pass for a checkout")
  (assert (nil? (os/lstat (clone/staging-path crashed)))
          "a failed clone leaves no staging directory")

  (set messages @[])
  (def vanished (path/join dir "vanished"))
  (assert (= :failed
             (clone/clone-repository (process/find-executable "true")
                                     (fn [& args] (array/push messages (string ;args)))
                                     "unused" vanished))
          "a VCS that succeeds without writing a clone has failed")
  (assert (= 1 (length messages)) "the failed move is one block")
  (assert (string/has-prefix? (string "✗ " vanished " (exit 1)\n! ") (messages 0))
          "the failed move is reported as what went wrong")

  (set messages @[])
  (def shown (path/join dir "shown"))
  (def talking-vcs (fake-vcs "talking" `echo said; mkdir -p "$dest/.git"`))
  (assert (= :cloned
             (clone/clone-repository talking-vcs
                                     (fn [& args] (array/push messages (string ;args)))
                                     "unused" shown nil "always")))
  (assert (deep= @[(string "✓ " shown "\n| said")] messages)
          "show-output always shows what a successful clone printed")

  (set messages @[])
  (def hidden (path/join dir "hidden"))
  (assert (= :failed
             (clone/clone-repository (process/find-executable "false")
                                     (fn [& args] (array/push messages (string ;args)))
                                     "unused" hidden nil "never")))
  (assert (empty? messages) "show-output never hides a failure"))

(def result
  (clone/clone-repositories [{:path existing :clone-url "unused"}
                             {:path occupied :clone-url "unused"}]))
(assert (= 1 ((result :counts) :present)) "clone-repositories keeps outcome counts")
(assert (= 1 ((result :counts) :blocked)))
(assert (= 0 ((result :counts) :failed)))

(sh/rm dir)

(end-suite)
