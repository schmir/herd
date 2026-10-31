# Tests for running a subprocess and collecting what it did.
(use spork/test)
(import ../src/process)

(start-suite "process")

(defn test-a-child-reads-no-input-by-default
  "A child that nobody gave input to finds nothing to read, rather than the terminal."
  []
  (def result (process/capture ["cat"] :p))
  (assert (= "" (string (result :out))) "cat reads an empty standard input")
  (assert (zero? (result :status))))

(defn test-a-child-reads-what-it-is-given
  "An input the caller names is the one the child reads."
  []
  (with [input (file/temp)]
    (file/write input "given")
    (file/flush input)
    (file/seek input :set 0)
    (def result (process/capture ["cat"] :p {:in input}))
    (assert (= "given" (string (result :out))))))

(defn test-no-descriptor-outlives-a-capture
  "Neither the default input nor one the caller names leaves a descriptor open."
  []
  (def open-descriptors (fn [] (length (os/dir "/dev/fd"))))
  (def interval (gcinterval))
  (defer (do (gcsetinterval interval) (gccollect))
    # Held off, since the collector closes what it reclaims and would hide a leak.
    (gcsetinterval 0x7FFFFFFF)
    (gccollect)
    (with [input (file/open "/dev/null" :r)]
      (def before (open-descriptors))
      (for _ 0 20 (process/capture ["true"] :p))
      (for _ 0 20 (process/capture ["true"] :p {:in input}))
      (assert (<= (open-descriptors) (+ before 2))
              "forty captures leave no descriptor behind"))))

(defn child-environment
  "What the child sees of the prompting variables, with `env` handed to capture."
  [&opt env]
  (def script `echo "$GIT_TERMINAL_PROMPT $SSH_ASKPASS $SSH_ASKPASS_REQUIRE"`)
  (string/trim (string ((process/capture ["sh" "-c" script] :p env) :out))))

(defn test-a-child-is-told-not-to-prompt
  ``A child is told to fail rather than ask on the terminal, unless the user has
  said how prompting should work, and the rest of the environment still reaches it.``
  []
  (def names ["GIT_TERMINAL_PROMPT" "SSH_ASKPASS" "SSH_ASKPASS_REQUIRE"])
  (def saved (map os/getenv names))
  (defer (map os/setenv names saved)
    (each name names (os/setenv name nil))
    (assert (= "0 false force" (child-environment))
            "git and ssh are told not to prompt")
    (os/setenv "SSH_ASKPASS" "my-askpass")
    (assert (= "0 my-askpass force" (child-environment))
            "an askpass program the user set is kept, and is what ssh asks")
    (os/setenv "SSH_ASKPASS_REQUIRE" "never")
    (assert (= "0 my-askpass never" (child-environment))
            "a user's own answer about askpass is kept")
    (assert (= "1 my-askpass never" (child-environment {"GIT_TERMINAL_PROMPT" "1"}))
            "what the caller gives wins over both"))
  (os/setenv "HERD_TEST_INHERITED" "kept")
  (defer (os/setenv "HERD_TEST_INHERITED" nil)
    (assert (= "kept\n"
               (string ((process/capture ["sh" "-c" `echo "$HERD_TEST_INHERITED"`] :p) :out)))
            "herd's own environment is inherited")))

(test-a-child-reads-no-input-by-default)
(test-a-child-is-told-not-to-prompt)
(test-a-child-reads-what-it-is-given)
(test-no-descriptor-outlives-a-capture)

(defn test-shell-argv
  "A command follows the shell vector, with its program as $0 and the arguments after."
  []
  (assert (deep= ["sh" "-c" "true" "sh"] (process/shell-argv "true" []))
          "sh -c is the default shell")
  (assert (deep= ["bash" "-e" "-c" `echo "$@"` "bash" "a b"]
                 (process/shell-argv `echo "$@"` ["a b"] ["bash" "-e" "-c"]))
          "a configured shell takes the command, its name as $0, then the arguments")
  (assert (= "bash\n"
             (string ((process/capture (process/shell-argv `echo "$0"` [] ["bash" "-c"]) :p) :out)))
          "the command runs in the configured shell"))

(test-shell-argv)

(end-suite)
