# Tests for clone outcomes after parallel runner integration.
(use spork/test)
(import spork/path)
(import spork/sh)
(import ../checkout)
(import ../clone)
(import ../process)

(start-suite "clone")

(def dir (path/join (os/getenv "TMPDIR" "/tmp")
                    (string "herd-clone-test-" (os/getpid))))
(sh/rm dir)
(sh/create-dirs dir)

(def existing (path/join dir "existing"))
(sh/create-dirs (path/join existing ".git"))
(assert (= :skipped (clone/clone-repository nil nil nil existing "unused"))
        "an existing checkout does not start a process")

(def occupied (path/join dir "occupied"))
(sh/create-dirs occupied)
(spit (path/join occupied "file") "present")
(var blocked-messages @[])
(assert (= :blocked (clone/clone-repository nil nil
                                            (fn [& args] (array/push blocked-messages (string ;args)))
                                            occupied "unused"))
        "something that is not a repository blocks the clone")
(assert (deep= @[(string "Clone blocked: " occupied
                         " holds something that is not a repository")]
               blocked-messages))

(assert (deep= ["git-bin" "clone" "--" "url" "checkout"]
               (clone/clone-process-command "git" "git-bin" "url" "checkout"))
        "git clone uses the native Git argument form")
(assert (deep= ["jj-bin" "git" "clone" "--colocate" "--" "url" "checkout"]
               (clone/clone-process-command "jj" "jj-bin" "url" "checkout"))
        "jj clone creates a colocated repository")

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

(with [devnull (file/open "/dev/null" :r)]
  (def env {:in devnull :out :pipe :err :pipe})
  (var messages @[])
  (def success (path/join dir "success"))
  (assert (= :cloned
             (clone/clone-repository cloning-vcs env
                                     (fn [& args] (array/push messages (string ;args)))
                                     success "unused")))
  (assert (= 1 (length messages)) "a successful clone reports completion")
  (assert (= :directory (os/stat (path/join success ".git") :mode))
          "a successful clone is moved into place")
  (assert (nil? (os/lstat (clone/staging-path success)))
          "a successful clone leaves no staging directory")

  (def empty (path/join dir "empty"))
  (sh/create-dirs empty)
  (assert (= :cloned (clone/clone-repository cloning-vcs env (fn [&]) empty
                                             "unused"))
          "an empty directory is cloned into")
  (assert (= :directory (os/stat (path/join empty ".git") :mode)))

  (def link-target (path/join dir "link-target"))
  (def link (path/join dir "link"))
  (sh/create-dirs link-target)
  (os/symlink "link-target" link)
  (assert (= :cloned (clone/clone-repository cloning-vcs env (fn [&]) link
                                             "unused"))
          "a link to an empty directory is cloned through")
  (assert (= :link (os/lstat link :mode)) "the link is kept")
  (assert (= :directory (os/stat (path/join link-target ".git") :mode)))

  (def leftover (path/join dir "leftover"))
  (sh/create-dirs (path/join (clone/staging-path leftover) ".git"))
  (assert (= :cloned (clone/clone-repository cloning-vcs env (fn [&]) leftover
                                             "unused"))
          "what an earlier crashed clone staged does not stop the next one")

  (set messages @[])
  (def failure (path/join dir "failure"))
  (assert (= :failed
             (clone/clone-repository (process/find-executable "false") env
                                     (fn [& args] (array/push messages (string ;args)))
                                     failure "unused")))
  (assert (= 1 (length messages)) "a failed clone reports its path")

  (def crashed (path/join dir "crashed"))
  (assert (= :failed (clone/clone-repository dying-vcs env (fn [&]) crashed
                                             "unused")))
  (assert (= "missing" (checkout/checkout-status {:path crashed}))
          "a clone that dies half-written does not pass for a checkout")
  (assert (nil? (os/lstat (clone/staging-path crashed)))
          "a failed clone leaves no staging directory")

  (set messages @[])
  (def vanished (path/join dir "vanished"))
  (assert (= :failed
             (clone/clone-repository (process/find-executable "true") env
                                     (fn [& args] (array/push messages (string ;args)))
                                     vanished "unused"))
          "a VCS that succeeds without writing a clone has failed")
  (assert (= 2 (length messages)) "the failed move is reported"))

(def counts
  (clone/clone-repositories [{:path existing :ssh_url "unused"}
                             {:path occupied :ssh_url "unused"}]))
(assert (= 1 (counts :skipped)) "clone-repositories keeps outcome counts")
(assert (= 1 (counts :blocked)))
(assert (= 0 (counts :failed)))

(sh/rm dir)

(end-suite)
