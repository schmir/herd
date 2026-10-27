# Tests for the shell completion scripts.
(use spork/test)
(import ../src/completions)
(import ../src/options)

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
    (each command ["clone" "list" "run" "completions" "tree"]
      (each long (map (fn [option] (option :name)) (options/for-command command))
        (assert (string/find long text)
                (string shell " offers --" long " for " command))))))

(defn test-menus-describe-every-option
  "The zsh and fish menus describe each option, in the short form where there is one."
  []
  (each shell ["zsh" "fish"]
    (def text (completions/script shell))
    (each command ["clone" "list" "run" "completions" "tree"]
      (each option (options/for-command command)
        (assert (string/find (or (option :summary) (option :help)) text)
                (string shell " describes --" (option :name) " for " command))))
    (each option options/top-level
      (assert (string/find (option :help) text)
              (string shell " describes the top-level --" (option :name))))))

(defn test-every-shell-offers-the-top-level-options
  "Bare herd offers --help and --version in every shell."
  []
  (each shell completions/shells
    (def text (completions/script shell))
    (each option options/top-level
      (assert (or (string/find (string "--" (option :name)) text)
                  (string/find (string " -l " (option :name)) text))
              (string shell " offers --" (option :name))))))

(defn test-subcommand-lines
  "Commands are listed by name, each with its summary after a tab."
  []
  (assert (= "a\tfirst\nb\tsecond"
             (completions/subcommand-lines {"b" {:help "second"}
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

(defn test-scripts-complete-show-output-values
  "Each script offers the conditions --show-output accepts."
  []
  (each shell completions/shells
    (assert (string/find "never on-failure always" (completions/script shell))
            (string shell " completes --show-output values"))))

(defn test-scripts-complete-directories-after-at
  "Each script completes directories for the --at option."
  []
  (each [shell needle] [["bash" "compgen -d"]
                        ["fish" "__fish_complete_directories"]
                        ["zsh" "_files -/"]]
    (assert (string/find needle (completions/script shell))
            (string shell " completes directories for --at"))))

(defn test-scripts-complete-the-command-after-run
  "Each script completes the command that herd run runs, and its arguments."
  []
  (each [shell needle] [["bash" "_command_offset"]
                        ["fish" "__fish_complete_subcommand"]
                        ["zsh" "'*::command:_normal'"]]
    (assert (string/find needle (completions/script shell))
            (string shell " completes the command after run"))))

(defn test-bash-offers-nothing-after-numeric-options
  "bash offers no completions where an option wants a number."
  []
  (assert (string/find "-j|--jobs|-n|--limit|--max-depth)" (completions/script "bash"))
          "bash returns no completions after -j, --jobs, -n, --limit and --max-depth"))

(defn test-bash-skips-option-values
  "The bash scanner skips the value of every option that takes one."
  []
  (def text (completions/script "bash"))
  (each flag ["-C" "--at" "-f" "--filter" "-j" "--jobs" "-n" "--limit" "--show-output"]
    (assert (or (string/find (string flag "|") text)
                (string/find (string flag ") ((i++))") text))
            (string "bash skips the value of " flag))))

(test-every-shell-has-a-script)
(test-bash-skips-option-values)
(test-scripts-offer-every-option)
(test-menus-describe-every-option)
(test-every-shell-offers-the-top-level-options)
(test-subcommand-lines)
(test-filter-lines)
(test-scripts-complete-the-command-after-run)
(test-bash-offers-nothing-after-numeric-options)
(test-scripts-complete-directories-after-at)
(test-scripts-complete-show-output-values)
(test-scripts-complete-filter-names)

(end-suite)
