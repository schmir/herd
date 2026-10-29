# Tests for showing text through a pager.
(use spork/test)
(import spork/sh)
(import ../src/pager)

(start-suite "pager")

(defn- printed
  "What `f` printed to stdout."
  [f]
  (def out @"")
  (with-dyns [:out out] (f))
  (string out))

(defn test-text-without-a-pager-is-printed
  "Text not colored for a terminal, or with the pager turned off, is printed."
  []
  (assert (= "text\n" (printed (fn [] (pager/page "text\n" false "false"))))
          "text not colored for a terminal skips the pager")
  (assert (= "text\n" (printed (fn [] (pager/page "text\n" true false))))
          "false turns the pager off"))

(defn test-colored-text-goes-through-the-pager
  "Colored text goes to the pager's standard input, and is not printed."
  []
  (def dir (string (os/getenv "TMPDIR" "/tmp") "/herd-pager-test-" (os/getpid)))
  (sh/create-dirs dir)
  (def paged (string dir "/paged"))
  (def out (printed (fn [] (pager/page "text\n" true (string `cat > "` paged `"`)))))
  (assert (= "" out) "the paged text is not printed as well")
  (assert (= "text\n" (string (slurp paged))) "the pager reads the text")
  (sh/rm dir))

(defn test-nothing-to-show-starts-no-pager
  "Empty text does not start the pager, which would only flash the screen."
  []
  (def dir (string (os/getenv "TMPDIR" "/tmp") "/herd-pager-test-" (os/getpid)))
  (sh/create-dirs dir)
  (def started (string dir "/started"))
  (pager/page "" true (string `touch "` started `"`))
  (assert (nil? (os/stat started)) "the pager does not run")
  (sh/rm dir))

(test-text-without-a-pager-is-printed)
(test-colored-text-goes-through-the-pager)
(test-nothing-to-show-starts-no-pager)

(end-suite)
