# Tests for tools/build-deps.sh, which fetches the JPM dependencies. jpm is a
# stub that records what it found when it ran.
(use spork/test)
(import spork/path)
(import spork/sh)

(start-suite "build-deps")

(def script "tools/build-deps.sh")

(def dir
  (path/join (os/getenv "TMPDIR" "/tmp") (string "herd-build-deps-test-" (os/getpid))))
(sh/rm dir)

(def bin (path/join dir "bin"))
(sh/create-dirs bin)
(def stub (path/join bin "jpm"))
(spit stub
      ``
      #!/bin/sh
      {
        echo "args: $*"
        if [ -d "$CHECKOUT" ]; then
          echo "checkout: present"
          ls -A "$CHECKOUT" | sed 's/^/  /'
        else
          echo "checkout: absent"
        fi
      } >> "$LOG"
      exit "${STUB_EXIT:-0}"
      ``)
(os/chmod stub 8r755)

(var counter 0)

(defn- scenario
  "Run the script with a fresh checkout path `layout` has prepared, and return
  {:status :log :checkout}. `layout` is called with the checkout path."
  [layout &opt stub-exit]
  (++ counter)
  (def root (path/join dir (string "case-" counter)))
  (def checkout (path/join root "jpm_tree/lib/.cache/spork.git"))
  (def log (path/join root "log"))
  (sh/create-dirs root)
  (layout checkout)
  (def status
    (os/execute ["bash" script checkout] :pe
                (merge (os/environ)
                       {"PATH" (string bin ":" (os/getenv "PATH"))
                        "CHECKOUT" checkout
                        "LOG" log
                        "STUB_EXIT" (string (or stub-exit 0))})))
  {:status status
   :log (if (os/stat log) (slurp log) "")
   :checkout checkout})

(defn test-the-empty-directories-ninja-made-are-gone-when-jpm-runs
  "jpm must not find the checkout directory, or it runs git fetch in it."
  []
  (def result (scenario (fn [checkout] (sh/create-dirs (path/join checkout "src")))))
  (assert (zero? (result :status)))
  (assert (string/find "checkout: absent" (result :log))
          "the empty checkout directory is removed before jpm runs")
  (assert (nil? (os/stat (result :checkout))) "and it stays removed"))

(defn test-an-empty-checkout-directory-without-src-is-removed
  "The directory alone is enough to mislead jpm."
  []
  (def result (scenario (fn [checkout] (sh/create-dirs checkout))))
  (assert (string/find "checkout: absent" (result :log))))

(defn test-a-real-checkout-is-left-alone
  "A directory with a repository and sources in it is what jpm should update."
  []
  (def result
    (scenario (fn [checkout]
                (sh/create-dirs (path/join checkout ".git"))
                (sh/create-dirs (path/join checkout "src"))
                (spit (path/join checkout "src/crc.c") "int x;"))))
  (assert (zero? (result :status)))
  (assert (string/find "checkout: present" (result :log)))
  (assert (= "int x;" (string (slurp (path/join (result :checkout) "src/crc.c"))))
          "the sources are untouched")
  (assert (os/stat (path/join (result :checkout) ".git")) "and so is the repository"))

(defn test-a-directory-with-something-in-it-is-left-alone
  "Even without a repository, rmdir removes nothing that holds a file, so work in
  progress is not thrown away."
  []
  (def result
    (scenario (fn [checkout]
                (sh/create-dirs (path/join checkout "src"))
                (spit (path/join checkout "src/partial.c") "x"))))
  (assert (string/find "checkout: present" (result :log)))
  (assert (os/stat (path/join (result :checkout) "src/partial.c"))))

(defn test-a-missing-cache-is-fine
  "On a first run there is nothing to remove, and that is not an error."
  []
  (def result (scenario (fn [_] nil)))
  (assert (zero? (result :status)))
  (assert (string/find "checkout: absent" (result :log))))

(defn test-jpm-is-asked-to-fetch-the-dependencies-locally
  "The command is jpm --local deps, once."
  []
  (def result (scenario (fn [_] nil)))
  (assert (= 1 (length (string/find-all "args: " (result :log)))) "jpm runs once")
  (assert (string/find "args: --local deps\n" (result :log))))

(defn test-a-failure-of-jpm-is-the-failure-of-the-script
  "ninja has to see that the step failed."
  []
  (assert (= 3 ((scenario (fn [_] nil) 3) :status))))

(defn test-the-checkout-directory-is-required
  "Without it the script would remove nothing and say nothing."
  []
  (def status
    (os/execute ["bash" script] :pe
                (merge (os/environ) {"PATH" (string bin ":" (os/getenv "PATH"))})))
  (assert (not (zero? status))))

(test-the-empty-directories-ninja-made-are-gone-when-jpm-runs)
(test-an-empty-checkout-directory-without-src-is-removed)
(test-a-real-checkout-is-left-alone)
(test-a-directory-with-something-in-it-is-left-alone)
(test-a-missing-cache-is-fine)
(test-jpm-is-asked-to-fetch-the-dependencies-locally)
(test-a-failure-of-jpm-is-the-failure-of-the-script)
(test-the-checkout-directory-is-required)

(sh/rm dir)

(end-suite)
