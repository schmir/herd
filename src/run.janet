# Running one command in each repository and reporting what it printed.

(import spork/path)
(import ./checkout)
(import ./location)
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

(def- stdout-gutter
  "What each line a command wrote to stdout is printed behind."
  "| ")

(def- stderr-gutter
  ``What each line a command wrote to stderr is printed behind, so the two
  streams stay apart without a label line naming each.``
  "! ")

(def- succeeded-color
  "The escape sequence that starts the color a succeeded heading is printed in."
  "\e[32m")

(def- failed-color
  "The escape sequence that starts the color a failed heading is printed in."
  "\e[31m")

(def- gutter-color
  "The escape sequence that starts the dimmed gutter of the output lines."
  "\e[2m")

(defn- paint
  "The `text`, in `color` when `color?`."
  [text color color?]
  (if color?
    (string color text "\e[0m")
    text))

(defn- indent-command-output
  ``Prefix each captured output line so command text is distinct from herd.
  With `color?`, the gutter is dimmed and the line itself left as it is.``
  [output gutter &opt color?]
  (def gutter (paint gutter gutter-color color?))
  (string/join
    (map (fn [line] (string gutter line)) (string/split "\n" (string/trimr output)))
    "\n"))

(defn- format-command-result
  ``Format one command result as a coherent output block. With `color?`, the
  heading is green when the command succeeded and red when it failed, and the
  gutter of the output lines is dimmed.``
  [repository status stdout stderr &opt color?]
  (def heading
    (if (zero? status)
      (paint (string "✓ " (repository :path)) succeeded-color color?)
      (paint (string "✗ " (repository :path) " (exit " status ")") failed-color color?)))
  (def sections @[heading])
  (when (pos? (length stdout))
    (array/push sections (indent-command-output stdout stdout-gutter color?)))
  (when (pos? (length stderr))
    (array/push sections (indent-command-output stderr stderr-gutter color?)))
  (string/join sections "\n"))

(defn with-arguments
  ``Return the configured `command`, a string or VCS-specific commands, with
  each command string made an argument vector that runs it in `shell` and
  passes `arguments` on to it.``
  [command arguments &opt shell]
  (if (string? command)
    (process/shell-argv command arguments shell)
    (tabseq [[key selected] :pairs command]
      key (process/shell-argv selected arguments shell))))

(defn argv-for-repository
  "Return the process command selected for repository."
  [repository command]
  (cond
    (string? command)
    (process/shell-argv command [])

    (dictionary? command)
    (if-let [vcs-id (vcs/detect (repository :path))]
      (do
        (def key (vcs/command-key vcs-id))
        (def selected (get command key))
        (cond
          (nil? selected) nil
          (string? selected) (process/shell-argv selected [])
          # A custom command given arguments has an argument vector each.
          (indexed? selected) selected
          (error (string "VCS-specific command needs a string " key))))
      (error "repository has no .git or .jj metadata"))

    # herd run passes an argument vector instead of a configured command.
    (indexed? command)
    command

    (error "command must be a string, VCS-specific command, or argument vector")))

(defn command-environment
  ``The environment a command runs in: herd's own, plus HERD_COLOR, "always"
  with `color?` and "never" without, for a command to pass on as its --color,
  and HERD_REPO_ANCHOR, HERD_REPO_PATH, HERD_REPO_URL and HERD_REPO_VCS
  describing the repository it runs in. HERD_REPO_PATH is its path beneath
  HERD_REPO_ANCHOR, the first of its anchors, as the repository list gives
  it once stripped, so it is absolute only when the list's is. A repository
  without an anchor has an empty one and its absolute path. HERD_AT_PATH is
  `at`, the location the repositories were selected from, the working
  directory unless given, and HERD_REPO_RELPATH the repository's path
  relative to it.
  Both have their symlinks resolved, as selection weighs them, so a
  repository containing `at` is `..` or further up, never a detour.``
  [repository color? &opt at]
  (def resolved-at (location/resolved-path (or at (os/cwd))))
  (merge (os/environ)
         {"HERD_COLOR" (if color? "always" "never")
          "HERD_AT_PATH" resolved-at
          "HERD_REPO_RELPATH" (path/relpath resolved-at
                                            (location/resolved-path (repository :path)))
          "HERD_REPO_ANCHOR" (get-in repository [:anchors 0] "")
          "HERD_REPO_PATH" (get repository :anchored-path (repository :path))
          "HERD_REPO_URL" (get repository :clone-url "")
          "HERD_REPO_VCS" (if-let [vcs-id (vcs/detect (repository :path))]
                            (vcs/name vcs-id)
                            "")}))

(defn run-in-repository
  ``Run and capture a command in a repository without changing herd's cwd.
  `reserve`, when given, is called once the command is known to run here,
  right before it starts. With `color?`, a result is printed in color. `at`
  is the location the repositories were selected from.``
  [repository command report &opt show-output reserve color? at]
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
                        :pe
                        (command-environment repository color? at)))
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
            (report (format-command-result repository status stdout stderr color?)))
          (if succeeded :succeeded :failed))
        :no-command)
      :not-checked-out)
    ([err]
      (unless (= "never" show-output)
        (report (paint (string "✗ " (repository :path)) failed-color color?) "\n"
                (indent-command-output (string err) stderr-gutter color?)))
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
  those it skips or finds not checked out do not count. The results are
  printed to stdout, as what the command produced, and with `color?` in
  color. `at` is the location the repositories were selected from, which
  each command is told its repository's path relative to.``
  [repositories command &opt show-output jobs limit color? at]
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
                         reserve
                         color?
                         at))
    jobs
    nil
    stop?
    stdout))
