# Tests for the declarations of the command line's options.
(use spork/test)
(import ../src/options)

(start-suite "options")

(defn- names
  "The names of `command`'s options, in order."
  [command]
  (map (fn [option] (option :name)) (options/for-command command)))

(defn test-each-command-declares-its-options
  "A command's options come in the order its help and its scripts list them."
  []
  (assert (deep= @["at" "all-anchors" "filter" "help" "jobs"] (names "clone")))
  (assert (deep= @["at" "all-anchors" "filter" "help" "sample" "ok" "missing" "extra"
                   "status" "tree" "max-depth" "hidden" "follow-links" "dirty" "clean"]
                 (names "list")))
  (assert (deep= @["help"] (names "completions")))
  (assert (deep= @["help" "repositories"] (names "tree")))
  (assert (deep= @["at" "all-anchors" "filter" "help" "sample" "show-output" "pager"
                   "no-pager" "jobs" "limit" "dirty" "clean"]
                 (names "run")))
  (assert (deep= (names "run") (names "a-command-from-config"))
          "a command the configuration defines takes what run does"))

(defn test-top-level-options
  "Bare herd takes help, config and version."
  []
  (assert (deep= @["help" "config" "version"]
                 (map (fn [option] (option :name)) options/top-level))))

(defn test-options-are-well-formed
  "Every option has a name, a kind and help, and a value name when it takes one."
  []
  (each command ["clone" "list" "completions" "run"]
    (each option (options/for-command command)
      (assert (string? (option :name)) "a name")
      (assert (index-of (option :kind) [:flag :option :accumulate])
              (string (option :name) " has a known kind"))
      (assert (and (string? (option :help)) (not (empty? (option :help))))
              (string (option :name) " has help"))
      (assert (= (not (nil? (option :value-name)))
                 (not= :flag (option :kind)))
              (string (option :name) " has a value name exactly when it takes a value"))
      (assert (nil? (option :default))
              (string (option :name) " names no default; the program supplies them")))))

(defn test-a-summary-only-where-help-is-long
  "Completion menus get a short summary for the options whose help runs long."
  []
  (each command ["clone" "list" "completions" "run"]
    (each option (options/for-command command)
      (when (option :summary)
        (assert (< (length (option :summary)) (length (option :help)))
                (string (option :name) "'s summary is shorter than its help")))
      (assert (or (option :summary) (<= (length (option :help)) 80))
              (string (option :name) " has long help and no summary"))))
  (assert (= "Print the status of each repository first."
             (get (find (fn [option] (= "status" (option :name)))
                        (options/for-command "list"))
                  :summary))))

(test-each-command-declares-its-options)
(test-top-level-options)
(test-options-are-well-formed)
(test-a-summary-only-where-help-is-long)

(end-suite)
