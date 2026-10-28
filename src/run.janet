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

(defn- shell-argv
  ``The argument vector that runs the shell `command` with `arguments` as its
  positional parameters, for the command to use as "$@", $1 and so on. They
  are never part of the shell's input.``
  [command arguments]
  ["sh" "-c" command "sh" ;arguments])

(defn with-arguments
  ``Return the configured `command`, a string or VCS-specific commands, with
  each command string made an argument vector that passes `arguments` on to
  it.``
  [command arguments]
  (if (string? command)
    (shell-argv command arguments)
    (tabseq [[key selected] :pairs command]
      key (shell-argv selected arguments))))

(defn argv-for-repository
  "Return the process command selected for repository."
  [repository command]
  (cond
    (string? command)
    (shell-argv command [])

    (dictionary? command)
    (if-let [vcs-id (vcs/detect (repository :path))]
      (do
        (def key (vcs/command-key vcs-id))
        (def selected (get command key))
        (cond
          (nil? selected) nil
          (string? selected) (shell-argv selected [])
          # A custom command given arguments has an argument vector each.
          (indexed? selected) selected
          (error (string "VCS-specific command needs a string " key))))
      (error "repository has no .git or .jj metadata"))

    # herd run passes an argument vector instead of a configured command.
    (indexed? command)
    command

    (error "command must be a string, VCS-specific command, or argument vector")))

(defn run-in-repository
  ``Run and capture a command in a repository without changing herd's cwd.
  `reserve`, when given, is called once the command is known to run here,
  right before it starts.``
  [repository command report &opt show-output reserve]
  (def show-output (require-show-output (or show-output default-show-output)))
  (try
    # A blocked path holds no working copy to run in, so it counts as not
    # checked out rather than as a place to run the command.
    (if (= :ok (checkout/checkout-status repository))
      (if-let [selected (argv-for-repository repository command)]
        (do
          (when reserve (reserve))
          (def result (process/capture
                        ["sh" "-c" `cd "$1" && shift && exec "$@"`
                         "herd" (repository :path) ;selected]
                        :p))
          (def stdout (result :out))
          (def stderr (result :err))
          (def status (result :status))
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
        :no-command)
      :not-checked-out)
    ([err]
      (unless (= "never" show-output)
        (report "✗ " (repository :path) "\n"
                (indent-command-output (string err))))
      :failed)))

(defn report-command-result
  "Separate result blocks while preserving their completion order."
  [separator report & xs]
  (when (separator :needed?)
    (report ""))
  (put separator :needed? true)
  (report ;xs))

(defn run-in-repositories
  ``Run a command in parallel and return what parallel/for-each-repository does,
  with the succeeded, failed, no-command, and not-checked-out counts. With a
  `limit`, the run stops once the command has run in that many repositories;
  those it skips or finds not checked out do not count.``
  [repositories command &opt show-output jobs limit]
  (def show-output (require-show-output (or show-output default-show-output)))
  # Capture output per process so each visible result is one coherent block.
  (def block-separator @{:needed? false})
  # A worker asks stop? before it claims a repository and reserves right
  # before the command starts. Nothing in between yields, so no other worker
  # can take the budget it saw, and the command runs at most `limit` times.
  (def budget @{:left limit})
  (defn reserve []
    (when limit
      (unless (pos? (budget :left))
        (error "the run limit was used up before the command could start"))
      (update budget :left dec)))
  (defn stop? []
    (and limit (zero? (budget :left))))
  (parallel/for-each-repository
    repositories
    [[:succeeded "succeeded"]
     [:failed "failed"]
     [:no-command "skipped"]
     [:not-checked-out "not checked out"]]
    (fn [repository report]
      (run-in-repository repository command
                         (fn [& args] (report-command-result block-separator report ;args))
                         show-output
                         reserve))
    jobs
    nil
    stop?))
