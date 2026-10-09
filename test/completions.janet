# Tests for the shell completion scripts.
(use spork/test)
(import ../completions)

(start-suite "completions")

(defn test-every-shell-has-a-script
  "Each shell herd names gets a script, and others get none."
  []
  (each shell completions/shells
    (assert (completions/script shell) (string shell " has a script")))
  (assert (nil? (completions/script "tcsh")) "an unknown shell has none"))

(defn test-scripts-offer-every-option
  "Every option a command takes appears in each script, spelled out in full."
  []
  (each shell completions/shells
    (def text (completions/script shell))
    (each command ["clone" "list" "run" "completions"]
      (each [_ long] (completions/command-options command)
        (assert (string/find long text)
                (string shell " offers --" long " for " command))))))

(defn test-command-lines
  "Commands are listed by name, each with its summary after a tab."
  []
  (assert (= "a\tfirst\nb\tsecond"
             (completions/command-lines {"b" {:help "second"}
                                         "a" {:help "first"}}))))

(defn test-filter-lines
  "Filters are listed by name, each with its expression after a tab."
  []
  (assert (= "a\t[?a]\nb\t[?b]"
             (completions/filter-lines {"b" "[?b]" "a" "[?a]"})))
  (assert (= "" (completions/filter-lines {})) "no filters, no lines"))

(defn test-scripts-complete-filter-names
  "Each script asks herd for the filter names after the filter option."
  []
  (each shell completions/shells
    (assert (string/find "herd completions filters" (completions/script shell))
            (string shell " completes filter names"))))

(defn test-bash-skips-option-values
  "The bash scanner skips the value of every option that takes one."
  []
  (def text (completions/script "bash"))
  (each flag ["-C" "--at" "-f" "--filter" "-j" "--jobs" "--show-output"]
    (assert (or (string/find (string flag "|") text)
                (string/find (string flag ") ((i++))") text))
            (string "bash skips the value of " flag))))

(test-every-shell-has-a-script)
(test-bash-skips-option-values)
(test-scripts-offer-every-option)
(test-command-lines)
(test-filter-lines)
(test-scripts-complete-filter-names)

(end-suite)
