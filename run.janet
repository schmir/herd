# Running one command in each repository and reporting what it printed.

(import ./checkout)
(import ./parallel)
(import ./process)
(import ./vcs)

(def default-show-output
  "When to show command output, unless another default is set."
  "on-failure")

(def show-output-conditions
  "Valid conditions for showing command output."
  ["never" "on-failure" "always"])

(defn require-show-output
  ``Return condition, or raise an error when it is not a valid one. The
  command line and `:show-output` in a custom command are checked against
  the same names this runs on, so there is one spelling of the condition.``
  [condition]
  (unless (and (string? condition) (index-of condition show-output-conditions))
    (error `expected "never", "on-failure", or "always"`))
  condition)

(defn- indent-command-output
  "Prefix each captured output line so command text is distinct from herd."
  [output]
  (string/join
    (map (fn [line] (string "|   " line)) (string/split "\n" (string/trimr output)))
    "\n"))

(defn- format-command-result
  "Format one command result as a coherent output block."
  [repository status stdout stderr]
  (def heading
    (if (zero? status)
      (string "✓ " (repository :path))
      (string "✗ " (repository :path) " (exit " status ")")))
  (def sections @[heading])
  (when (pos? (length stdout))
    (array/push sections (string "| stdout\n" (indent-command-output stdout))))
  (when (pos? (length stderr))
    (array/push sections (string "| stderr\n" (indent-command-output stderr))))
  (string/join sections "\n"))

(defn command-for-repository
  "Return the process command selected for repository."
  [repository command]
  (cond
    (string? command)
    ["sh" "-c" command]

    (dictionary? command)
    (if-let [used (vcs/detect (repository :path))]
      (do
        (def key (vcs/command-key used))
        (def selected (get command key))
        (if (nil? selected)
          nil
          (do
            (unless (string? selected)
              (error (string "VCS command structure needs a string " key)))
            ["sh" "-c" selected])))
      (error "repository has no .git or .jj metadata"))

    # herd run passes an argument vector instead of a configured command.
    (indexed? command)
    command

    (error "command must be a string, VCS command structure, or argument vector")))

(defn run-in-repository
  "Run and capture a command in a repository without changing herd's cwd."
  [repository command report &opt show-output]
  (def show-output (require-show-output (or show-output default-show-output)))
  (try
    # A blocked path holds no working copy to run in, so it counts as not
    # checked out rather than as a place to run the command.
    (if (= :ok (checkout/checkout-status repository))
      (if-let [selected (command-for-repository repository command)]
        (let [result (process/capture-process
                       ["sh" "-c" `cd "$1" && shift && exec "$@"`
                        "herd" (repository :path) ;selected]
                       :p)
              stdout (result :out)
              stderr (result :err)
              status (result :status)]
          (def succeeded (zero? status))
          # A successful command that printed nothing has nothing to report:
          # its heading alone would only add noise. A failing one still needs
          # a heading, because the counts do not name the repository.
          (def worth-reporting
            (or (not succeeded)
                (pos? (+ (length stdout) (length stderr)))))
          (when (and worth-reporting
                     (case show-output
                       "never" false
                       "on-failure" (not succeeded)
                       "always" true))
            (report (format-command-result repository status stdout stderr)))
          (if succeeded :succeeded :failed))
        :skipped)
      :not-checked-out)
    ([err]
      (unless (= "never" show-output)
        (report "✗ " (repository :path) "\n"
                (indent-command-output (string err))))
      :failed)))

(defn report-command-result
  "Separate result blocks while preserving their completion order."
  [state report & xs]
  (when (state :reported)
    (report ""))
  (put state :reported true)
  (report ;xs))

(defn run-in-repositories
  ``Run a command in parallel and return what parallel/run-repositories does,
  with the succeeded, failed, skipped, and not-checked-out counts.``
  [repositories command &opt show-output jobs]
  (def show-output (require-show-output (or show-output default-show-output)))
  # Capture output per process so each visible result is one coherent block.
  (def report-state @{:reported false})
  (parallel/run-repositories
    repositories
    [[:succeeded "succeeded"]
     [:failed "failed"]
     [:skipped "skipped"]
     [:not-checked-out "not checked out"]]
    (fn [repository report]
      (run-in-repository repository command
                         (fn [& args] (report-command-result report-state report ;args))
                         show-output))
    jobs))
