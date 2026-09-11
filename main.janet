(import spork/argparse)
(import spork/json)
(import spork/path)
(import ./parallel)

(defmacro- baked-version
  ``The version named by HERD_VERSION, read while this file is compiled.
  Baking it in is what makes a downloaded binary able to say which release it
  is: looking the variable up at run time would only describe the machine the
  binary ended up on. A build that names no version is not a release.``
  []
  (def configured (os/getenv "HERD_VERSION"))
  (if (or (nil? configured) (empty? configured)) "dev" configured))

(def version
  "Version this build was compiled for."
  (baked-version))

(def default-vcs
  "The VCS used for repositories that do not select one."
  "jj")

(def default-show-output
  "When to show command output, unless another default is set."
  "on-failure")

(def show-output-conditions
  "Valid conditions for showing command output."
  ["never" "on-failure" "always"])

(def default-checkout-options
  ``Default checkout options. Their keys define the options that each
  configuration level accepts.``
  {:vcs default-vcs})

(def checkout-keys
  "Checkout option names accepted at each configuration level."
  (keys default-checkout-options))

(defn validate-checkout-options
  ``Validate checkout options and return `options`. Use `where` and the
  format-specific `spelling` in errors.``
  [options where &opt spelling]
  (default spelling ":vcs")
  (def vcs (get options :vcs :unset))
  (unless (= :unset vcs)
    (unless (and (string? vcs) (or (= "git" vcs) (= "jj" vcs)))
      (error (string where " has an invalid " spelling
                     "; expected \"git\" or \"jj\""))))
  options)

(defn find-executable
  "Find an executable file by searching the process PATH."
  [name]
  (some (fn [directory]
          (unless (empty? directory)
            (def candidate (string directory "/" name))
            (def info (os/stat candidate))
            (when (and info
                       (= :file (info :mode))
                       (string/find "x" (info :permissions)))
              candidate)))
        (string/split ":" (os/getenv "PATH" ""))))

(defn checked-out?
  "Check whether path already holds a checkout."
  [path]
  (and (= :directory (os/stat path :mode))
       (not (empty? (os/dir path)))))

(defn clone-process-command
  "Return the process command that clones url to path with vcs."
  [vcs executable url path]
  (case vcs
    "git" [executable "clone" "--" url path]
    "jj" [executable "git" "clone" "--colocate" "--" url path]
    (error (string "unsupported VCS " vcs))))

(defn clone-repository
  "Clone a repository with vcs unless it is already checked out.
  Return :skipped, :cloned, or :failed."
  [executable env report path url &opt vcs]
  (if (checked-out? path)
    :skipped
    (try
      (do
        (def command (clone-process-command (or vcs default-vcs)
                                            executable url path))
        (def process (os/spawn command : env))
        (def stdout @"")
        (def stderr @"")
        (ev/gather
          (:read (process :out) :all stdout)
          (:read (process :err) :all stderr)
          (:wait process))
        (if (zero? (process :return-code))
          (do
            (report "Clone complete: " path)
            :cloned)
          (do
            (report "Clone failed: " path)
            (when (> (length stderr) 0) (report stderr))
            (when (> (length stdout) 0) (report stdout))
            :failed)))
      ([err]
        (report "Clone failed: " path ": " err)
        :failed))))

(defn clone-repositories
  "Clone repositories with their selected VCS and limit concurrent processes.
  Return the cloned, skipped, and failed counts."
  [repositories &opt jobs]
  (def executables {"git" (find-executable "git")
                    "jj" (find-executable "jj")})
  # Clones must never inherit the terminal: several run at once, and a VCS
  # or SSH prompt on a shared stdin would interleave or hang the whole run.
  (with [devnull (file/open "/dev/null" :r)]
    (def env {:in devnull :out :pipe :err :pipe})
    (parallel/run-repositories
      repositories
      [[:cloned "cloned"]
       [:skipped "already checked out"]
       [:failed "failed"]]
      (fn [repository report]
        # Each checkout has its final VCS after loading.
        (def selected-vcs (get repository :vcs default-vcs))
        (def executable (get executables selected-vcs))
        (if (or executable (checked-out? (repository :path)))
          (clone-repository executable env report
                            (repository :path)
                            (repository :ssh_url)
                            selected-vcs)
          (do
            (report "Clone failed: " (repository :path) ": "
                    selected-vcs " was not found on PATH")
            :failed)))
      jobs)))

(defn validate-config
  "Return config unchanged, or raise a descriptive error describing its shape."
  [config]
  (unless (indexed? config)
    (error "expected a JSON array of repository objects"))
  (for index 0 (length config)
    (def entry (config index))
    (unless (dictionary? entry)
      (error (string "entry " index " is not a JSON object")))
    (each key [:path :ssh_url]
      (unless (string? (entry key))
        (error (string "entry " index " needs a string \"" key "\""))))
    (validate-checkout-options entry (string "entry " index) `"vcs"`))
  config)

(defn parse-config
  "Parse JSON source into Janet data."
  [source]
  (json/decode source true))

(defn config-directory
  ``Directory holding the JSON configuration files, or nil when neither
  XDG_CONFIG_HOME nor HOME is set.``
  []
  (if-let [xdg (os/getenv "XDG_CONFIG_HOME")]
    (path/join xdg "herd")
    (when-let [home (os/getenv "HOME")]
      (path/join home ".config" "herd"))))

(def config-suffix ".json")

(defn discover-config-files
  ``Configuration files in `directory`, sorted so the merge order is stable.
  A missing directory yields none: having no configuration yet is normal.``
  [directory]
  (def names (if directory (try (os/dir directory) ([_] @[])) @[]))
  (sort (seq [name :in names
              :when (string/has-suffix? config-suffix name)
              :let [file (path/join directory name)]
              :when (= :file (os/stat file :mode))]
          file)))

(def checkout-row-keys
  "Non-option keys that a checkout row can contain."
  [:from :anchor])

(defn- reject-unknown-setting
  "Raise for a setting that is not configurable."
  [where key known]
  (unless (index-of key known)
    (error (string where " has an unknown setting " (describe key)))))

(defn- validate-anchor-setting
  "Validate an optional anchor as a non-empty string."
  [settings where]
  (def anchor (get settings :anchor :unset))
  (unless (= :unset anchor)
    (unless (and (string? anchor) (not (empty? anchor)))
      (error (string where " needs a non-empty :anchor"))))
  settings)

(defn validate-checkout-row
  ``Validate one `:checkouts` row and return it. Each row must name a
  configuration file.``
  [row where]
  (unless (dictionary? row)
    (error (string where " must be a dictionary")))
  (eachk key row
    (reject-unknown-setting where key [;checkout-row-keys ;checkout-keys]))
  (def from (get row :from))
  (unless (and (string? from) (not (empty? from)))
    (error (string where " needs a :from naming a configuration file")))
  (validate-anchor-setting row where)
  (validate-checkout-options row where)
  row)

(defn validate-checkout-defaults
  "Validate `:defaults` and return them. Defaults cannot name a source."
  [defaults]
  (unless (dictionary? defaults)
    (error ":defaults must be a dictionary"))
  (eachk key defaults
    (reject-unknown-setting ":defaults" key [:anchor ;checkout-keys]))
  (validate-anchor-setting defaults ":defaults")
  (validate-checkout-options defaults ":defaults")
  defaults)

(def default-repository-settings
  "Repository settings used when config.jdn is absent."
  {:defaults {} :rows {}})

(defn configured-repository-settings
  ``Validate repository settings and group checkout rows by source.
  Preserve the row order for each source.``
  [config]
  (unless (dictionary? config)
    (error "expected a JDN dictionary"))
  (def configured (get config :checkouts []))
  (unless (indexed? configured)
    (error ":checkouts must be an array of rows"))
  (def rows @{})
  (for index 0 (length configured)
    (def row (validate-checkout-row (configured index)
                                    (string ":checkouts row " index)))
    (if-let [written (get rows (row :from))]
      (array/push written row)
      (put rows (row :from) @[row])))
  {:defaults (validate-checkout-defaults (get config :defaults {}))
   :rows rows})

(defn rows-for-file
  ``Merge each row for `name` with the defaults. Return the defaults alone
  when no row names the file.``
  [settings name]
  (def defaults (get settings :defaults {}))
  (if-let [configured (get-in settings [:rows name])]
    (map |(merge defaults $) configured)
    @[(merge defaults)]))

(defn- checkout-options
  "Return only the checkout options set in `source`."
  [source]
  (def options @{})
  (each key checkout-keys
    (def value (get source key))
    (unless (nil? value)
      (put options key value)))
  options)

(defn config-anchors
  ``Resolve one anchor for each checkout row and retain its options. Relative
  anchors use HOME. A missing anchor uses HOME for configured files and the
  file's parent otherwise. Keep configured paths because selection resolves
  symbolic links.``
  [config-path directory rows]
  (def parent (path/abspath (path/parent config-path)))
  (def name (path/basename config-path))
  (seq [row :in rows]
    (def anchor (get row :anchor))
    (def resolved
      (cond
        (nil? anchor)
        (if (and directory (= parent (path/abspath directory)))
          (or (os/getenv "HOME") parent)
          parent)

        (path/abspath? anchor)
        (path/abspath anchor)

        (if-let [home (os/getenv "HOME")]
          (with-dyns [:path-cwd home]
            (path/abspath anchor))
          (error (string "cannot resolve relative anchor for "
                         name " without HOME")))))
    (merge (checkout-options row) {:path resolved})))

(defn resolve-repository-paths
  ``Resolve each entry once per anchor and apply its checkout options. Entries
  without anchors produce no checkouts. Absolute paths remain the same under
  all anchors so `merge-configs` can combine them.``
  [entries anchors]
  (def resolved @[])
  (each anchor anchors
    (def options (checkout-options anchor))
    (with-dyns [:path-cwd (anchor :path)]
      (each entry entries
        # Apply options from least to most specific: defaults, anchor, entry.
        (array/push resolved
                    (merge default-checkout-options options entry
                           {:path (path/abspath (entry :path))
                            :anchors @[(anchor :path)]})))))
  resolved)

(defn read-config
  "Read one configuration file, resolving each repository into checkouts."
  [config-path directory rows]
  (resolve-repository-paths
    (validate-config (parse-config (slurp config-path)))
    (config-anchors config-path directory rows)))

(defn merge-configs
  ``Concatenate `[config-path entries]` pairs into one repository list. Two
  files may name the same checkout only when they agree on the URL and VCS;
  letting them disagree would make the result depend on the reading order.``
  [loaded]
  (def seen @{})
  (def merged @[])
  (each [config-path entries] loaded
    (each entry entries
      (def previous (get seen (entry :path)))
      (cond
        (nil? previous)
        (do
          (put seen (entry :path) {:source config-path
                                   :ssh_url (entry :ssh_url)
                                   :vcs (get entry :vcs)
                                   :anchors (entry :anchors)})
          (array/push merged entry))

        (not= (previous :ssh_url) (entry :ssh_url))
        (error (string/format "%s and %s disagree on the URL for %s"
                              (previous :source) config-path (entry :path)))

        (not= (get previous :vcs) (get entry :vcs))
        (error (string/format "%s and %s disagree on the VCS for %s"
                              (previous :source) config-path (entry :path)))

        true
        (each anchor (entry :anchors)
          (unless (some |(= anchor $) (previous :anchors))
            (array/push (previous :anchors) anchor))))))
  merged)

(defn- reject-unknown-sources
  ``Reject checkout rows whose source file is missing. This prevents a
  renamed list from silently using the defaults.``
  [settings config-paths]
  (def present (map |(path/basename $) config-paths))
  (each name (keys (get settings :rows {}))
    (unless (index-of name present)
      (error (string "config.jdn: :checkouts reads " (describe name)
                     ", which is not in the configuration directory")))))

(defn load-config
  ``Read every configuration file and merge them into one repository list.
  Errors name the file they came from, since a bad entry is otherwise hard to
  place once several files are in play.``
  [config-paths directory &opt settings]
  (default settings default-repository-settings)
  (reject-unknown-sources settings config-paths)
  (merge-configs
    (seq [config-path :in config-paths]
      [config-path
       (try
         (read-config config-path directory
                      (rows-for-file settings (path/basename config-path)))
         ([err] (error (string config-path ": " err))))])))

(defn- bare-path
  ``Drop trailing slashes, which normalisation keeps but comparison must not.``
  [path]
  (def trimmed (string/trimr path "/"))
  (if (empty? trimmed) "/" trimmed))

(defn- comparable-path
  ``Absolute `path` with the symlinks resolved in as much of it as exists.
  Selection weighs configured paths against a working directory, which the
  system already gave us resolved, so both sides have to name the same
  location the same way. A repository that is not checked out yet keeps the
  part that does not exist, which is why the whole path cannot just be
  resolved at once.``
  [path]
  (var head (bare-path (path/abspath path)))
  (def missing @[])
  (while (and (not= "/" head) (nil? (os/lstat head :mode)))
    (array/push missing (path/basename head))
    (set head (bare-path (path/parent head))))
  (def resolved (bare-path (try (os/realpath head) ([_] head))))
  (if (empty? missing)
    resolved
    (bare-path (path/join resolved ;(reverse missing)))))

(defn- holds-path?
  ``Whether `ancestor` is `descendant` or holds it somewhere below. Compares
  whole segments, so /srv/foobar is not held by /srv/foo.``
  [ancestor descendant]
  (or (= ancestor descendant)
      (string/has-prefix? (if (= "/" ancestor) ancestor (string ancestor "/"))
                          descendant)))

(defn containing-anchors
  "Return each configured anchor that contains path."
  [path repositories]
  (def root (comparable-path path))
  (def found @[])
  (each repository repositories
    (each anchor (get repository :anchors [])
      (def candidate (comparable-path anchor))
      (when (and (holds-path? candidate root)
                 (not (some |(= candidate $) found)))
        (array/push found candidate))))
  found)

(defn select-repositories-with-anchors
  "Filter repositories with anchors that were already selected."
  [path repositories all-anchors anchors]
  (def root (comparable-path path))
  (filter (fn [repository]
            (def candidate (comparable-path (repository :path)))
            (and (or all-anchors
                     (some (fn [repository-anchor]
                             (def normalized (comparable-path repository-anchor))
                             (some |(= normalized $) anchors))
                           (get repository :anchors [])))
                 (or (holds-path? root candidate)
                     (holds-path? candidate root))))
          repositories))

(defn- help-requested?
  ``Whether `args` asks for help. argparse prints usage and returns nil for
  both `--help` and a genuine mistake, so the two are told apart here.``
  [args]
  (var found false)
  (var options true)
  (each arg args
    (cond
      (= "--" arg) (set options false)
      (not options) nil
      (= "--help" arg) (set found true)
      (and (string/has-prefix? "-" arg)
           (not (string/has-prefix? "--" arg))
           (string/find "h" arg))
      (set found true)))
  found)

(defn- parse-args
  ``Parse `args` against an argparse specification, exiting on a mistake.
  Asking for help is not a mistake, so it leaves through the successful door.``
  [args & spec]
  (or (argparse/argparse ;spec :args args)
      (os/exit (if (help-requested? args) 0 1))))

(defn- configured-repositories
  "Load the configured repositories and select the ones at a path."
  [at all-anchors &opt settings]
  (default settings default-repository-settings)
  (def directory (config-directory))
  (when (nil? directory)
    (eprint "Neither XDG_CONFIG_HOME nor HOME is set, so there is no "
            "configuration directory to read")
    (os/exit 1))
  (def config-paths
    (try
      (discover-config-files directory)
      ([err]
        (eprint "Configuration error: " err)
        (os/exit 1))))
  # Validate checkout sources even when no repository lists exist.
  (def config
    (try
      (load-config config-paths directory settings)
      ([err]
        (eprint "Configuration error: " err)
        (os/exit 1))))
  # Nothing configured yet is a normal state, not a failure: exiting non-zero
  # would make `just run` print a traceback over an unremarkable message.
  (when (empty? config-paths)
    (eprint "No configuration files in " directory)
    (os/exit 0))
  (def anchors (unless all-anchors (containing-anchors at config)))
  (def selected
    (select-repositories-with-anchors at config all-anchors anchors))
  # Say why the result is empty. Since --at defaults to the current
  # directory, standing in the wrong place otherwise looks like a broken
  # configuration.
  (when (and (empty? selected) (not (empty? config)))
    (cond
      all-anchors
      (eprint "None of the " (length config) " configured repositories are beneath " at
              " or hold it")

      (empty? anchors)
      (eprint "No configuration anchor contains " at
              "; use -a/--all-anchors to consider every anchor")

      true
      (eprint "None of the configured repositories associated with an anchor "
              "containing " at " are beneath it or hold it; use "
              "-a/--all-anchors to consider every anchor")))
  selected)

(defn- at-option
  "The --at specification, shared by every selecting command."
  []
  {:kind :option
   :short "C"
   :value-name "PATH"
   :default (os/cwd)
   :help "Select repositories using PATH as the working location."})

(defn- all-anchors-option
  "The --all-anchors specification, shared by every selecting command."
  []
  {:kind :flag
   :short "a"
   :help "Consider repositories from every configuration anchor."})

(defn- show-output-option
  "Return the --show-output specification with default."
  [default]
  {:kind :option
   :value-name "WHEN"
   :default default
   :help "Show command output: never, on-failure, or always."})

(defn- jobs-option
  "Return the --jobs specification with default, shared by running commands."
  [&opt configured]
  (default configured parallel/default-jobs)
  {:kind :option
   :short "j"
   :value-name "N"
   :default (string configured)
   :help "Run at most N repository operations at the same time."})

(defn- require-jobs
  ``Return `count` as a positive integer, or raise a descriptive error.
  The accepted range is the one parallel/run-repositories accepts, so an
  out-of-range count fails here with a message instead of there with a
  stack trace.``
  [count]
  (def parsed (if (string? count) (scan-number count) count))
  (unless (and (int? parsed) (pos? parsed))
    (error "expected a positive integer no greater than 2147483647"))
  parsed)

(defn- require-show-output
  "Return condition, or raise an error when it is not a valid one."
  [condition]
  (unless (and (string? condition) (index-of condition show-output-conditions))
    (error `expected "never", "on-failure", or "always"`))
  condition)

(defn- parse-selection
  "Parse the selection arguments shared by every selecting command."
  [args description & spec]
  (parse-args args description
              "at" (at-option)
              "all-anchors" (all-anchors-option)
              ;spec))

(defn- parsed-jobs
  "Return the validated --jobs count, or report the mistake and exit."
  [parsed]
  (try
    (require-jobs (parsed "jobs"))
    ([err]
      (eprint "Invalid --jobs: " err)
      (os/exit 1))))

(defn- selected-repositories
  "Parse the selection arguments and load the repositories they select."
  [args description settings]
  (def parsed (parse-selection args description))
  (configured-repositories (parsed "at")
                           (parsed "all-anchors")
                           settings))

(defn clone-command
  "Run herd clone with each repository's configured VCS."
  [args &opt settings jobs]
  (def parsed
    (parse-selection args
                     "Check out the configured repositories beneath a path."
                     "jobs" (jobs-option jobs)))
  (def jobs (parsed-jobs parsed))
  (def repositories
    (configured-repositories (parsed "at") (parsed "all-anchors") settings))
  (def counts (clone-repositories repositories jobs))
  (print (counts :cloned) " cloned, "
         (counts :skipped) " already checked out, "
         (counts :failed) " failed")
  (when (pos? (counts :failed))
    (os/exit 1)))

(defn list-command
  ``Run `herd list`: print the selected repositories, one tab-separated path
  and URL per line, in the order the commands act on them.``
  [args &opt settings]
  (each entry (selected-repositories args
                                     "Print the configured repositories beneath a path."
                                     settings)
    (print (entry :path) "\t" (entry :ssh_url))))

(defn- indent-command-output
  "Prefix each captured output line so command text is distinct from herd."
  [output]
  (string/join
    (map |(string "|   " $) (string/split "\n" (string/trimr output)))
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

(defn repository-vcs
  "Return the VCS identified by repository metadata, or nil."
  [repository]
  (def root (repository :path))
  (cond
    (os/lstat (path/join root ".jj") :mode) :jj
    (os/lstat (path/join root ".git") :mode) :git))

(defn command-for-repository
  "Return the process command selected for repository."
  [command repository]
  (cond
    (string? command)
    ["sh" "-c" command]

    (dictionary? command)
    (if-let [vcs (repository-vcs repository)]
      (do
        (def key (case vcs
                   :git :command-git
                   :jj :command-jj))
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
  [command env repository report &opt show-output]
  (def show-output (require-show-output (or show-output default-show-output)))
  (try
    (if (checked-out? (repository :path))
      (if-let [selected (command-for-repository command repository)]
        (with [process
               (os/spawn ["sh" "-c" `cd "$1" && shift && exec "$@"`
                          "herd" (repository :path) ;selected]
                         :p env)]
          (def stdout @"")
          (def stderr @"")
          (ev/gather
            (:read (process :out) :all stdout)
            (:read (process :err) :all stderr)
            (:wait process))
          (def status (process :return-code))
          (def succeeded (zero? status))
          (when (case show-output
                  "never" false
                  "on-failure" (not succeeded)
                  "always" true)
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
  "Run a command in parallel and return its outcome counts."
  [command repositories &opt show-output jobs]
  (def show-output (require-show-output (or show-output default-show-output)))
  # Parallel commands must not share a terminal for input or output. Capture
  # output per process so each visible result is one coherent block.
  (with [devnull (file/open "/dev/null" :r)]
    (def env {:in devnull :out :pipe :err :pipe})
    (def report-state @{:reported false})
    (parallel/run-repositories
      repositories
      [[:succeeded "succeeded"]
       [:failed "failed"]
       [:skipped "skipped"]
       [:not-checked-out "not checked out"]]
      (fn [repository report]
        (run-in-repository command env repository
                           |(report-command-result report-state report ;$&)
                           show-output))
      jobs)))

(defn- run-configured-command
  "Run a command in the selected repositories and report its outcome."
  [command parsed &opt settings]
  (def show-output
    (try
      (require-show-output (parsed "show-output"))
      ([err]
        (eprint "Invalid --show-output: " err)
        (os/exit 1))))
  (def jobs (parsed-jobs parsed))
  (def repositories
    (configured-repositories (parsed "at") (parsed "all-anchors") settings))
  (def counts (run-in-repositories command repositories show-output jobs))
  (print (counts :succeeded) " succeeded, "
         (counts :failed) " failed, "
         (counts :skipped) " skipped, "
         (counts :not-checked-out) " not checked out")
  (when (pos? (counts :failed))
    (os/exit 1)))

(defn make-run-command
  "Return a handler that uses description for help and runs command."
  [command description &opt show-output jobs settings]
  (def show-output (or show-output default-show-output))
  (fn [args]
    (def parsed
      (parse-selection args description
                       "show-output" (show-output-option show-output)
                       "jobs" (jobs-option jobs)))
    (run-configured-command command parsed settings)))

(defn run-command
  "Run herd run with the command and repository selection in args."
  [args &opt jobs settings]
  (def parsed
    (parse-selection args
                     (string "Run a command in each configured repository beneath a path.\n\n"
                             " Usage: herd run [option] ... CMD [CMD-ARGS]...")
                     "show-output" (show-output-option default-show-output)
                     "jobs" (jobs-option jobs)
                     :default {:kind :accumulate
                               :short-circuit true
                               :help "Command and arguments to run."}))
  (def command (or (parsed :rest) @[]))
  (when (empty? command)
    (eprint "herd run needs a command")
    (os/exit 1))
  (run-configured-command command parsed settings))

(def built-in-command-help
  "One-line summaries for the built-in subcommands, by name."
  {"clone" "Check out the configured repositories beneath a path."
   "fetch" "Fetch Git remotes in configured repositories beneath a path."
   "list" "Print the configured repositories beneath a path."
   "run" "Run a command in each configured repository beneath a path."})

(defn built-in-commands
  ``Subcommands by name, with their argument handler and one-line summary.
  The per-file settings and job count are bound here so every handler starts
  from them, leaving the command line to override.``
  [&opt settings jobs]
  (default settings default-repository-settings)
  (default jobs parallel/default-jobs)
  {"clone" {:run (fn [args] (clone-command args settings jobs))
            :help (built-in-command-help "clone")}
   "fetch" {:run (make-run-command
                   {:command-git "git fetch"
                    :command-jj "jj git fetch"}
                   "Fetch Git remotes in each configured repository beneath a path."
                   default-show-output
                   jobs
                   settings)
            :help (built-in-command-help "fetch")}
   "list" {:run (fn [args] (list-command args settings))
           :help (built-in-command-help "list")}
   "run" {:run (fn [args] (run-command args jobs settings))
          :help (built-in-command-help "run")}})

(defn command-config-path
  "Return the JDN configuration path, or nil without a config directory."
  []
  (when-let [directory (config-directory)]
    (path/join directory "config.jdn")))

(defn configured-jobs
  "Return the configured job count, or the default when it is not set."
  [config]
  (unless (dictionary? config)
    (error "expected a JDN dictionary"))
  (def jobs (get config :jobs parallel/default-jobs))
  (unless (and (int? jobs) (pos? jobs))
    (error ":jobs must be a positive integer no greater than 2147483647"))
  jobs)

(def custom-command-keys
  "Keys a custom-command definition may contain."
  [:command :command-git :command-jj :description :show-output])

(defn command-from-definition
  "Return the command described by one custom-command definition."
  [name definition]
  (def command (get definition :command))
  (def command-git (get definition :command-git))
  (def command-jj (get definition :command-jj))
  (if (not (nil? command))
    (do
      (unless (string? command)
        (error (string "custom command \"" name "\" needs a string :command")))
      (when (or (not (nil? command-git)) (not (nil? command-jj)))
        (error (string "custom command \"" name
                       "\" cannot combine :command with VCS-specific commands")))
      command)
    (do
      (when (and (nil? command-git) (nil? command-jj))
        (error (string "custom command \"" name
                       "\" needs :command, :command-git, or :command-jj")))
      (unless (or (nil? command-git) (string? command-git))
        (error (string "custom command \"" name
                       "\" needs a string :command-git")))
      (unless (or (nil? command-jj) (string? command-jj))
        (error (string "custom command \"" name
                       "\" needs a string :command-jj")))
      {:command-git command-git :command-jj command-jj})))

(defn custom-commands
  "Validate a JDN configuration and return its command handlers."
  [config &opt jobs settings]
  (default jobs parallel/default-jobs)
  (unless (dictionary? config)
    (error "expected a JDN dictionary with a :commands dictionary"))
  (def configured (get config :commands {}))
  (unless (dictionary? configured)
    (error ":commands must be a dictionary"))
  (def result @{})
  (eachp [name definition] configured
    (unless (and (string? name) (not (empty? name)))
      (error "custom command names must be non-empty strings"))
    (when (get built-in-command-help name)
      (error (string "custom command \"" name "\" conflicts with a built-in command")))
    (unless (dictionary? definition)
      (error (string "custom command \"" name "\" must be a dictionary")))
    (eachk key definition
      (unless (index-of key custom-command-keys)
        (error (string "custom command \"" name "\" has an unknown key "
                       (describe key)))))
    (def command (command-from-definition name definition))
    (def description (get definition :description))
    (unless (string? description)
      (error (string "custom command \"" name "\" needs a string :description")))
    (def show-output (get definition :show-output default-show-output))
    (try
      (require-show-output show-output)
      ([err]
        (error (string "custom command \"" name
                       "\" has an invalid :show-output; " err))))
    (put result name
         {:run (make-run-command command description show-output jobs settings)
          :help description}))
  result)

(defn prepare-command-config
  "Validate raw JDN configuration and construct its command handlers."
  [config]
  (def jobs (configured-jobs config))
  (def settings (configured-repository-settings config))
  {:settings settings
   :jobs jobs
   :commands (custom-commands config jobs settings)})

(defn load-command-config
  "Read and validate JDN configuration, or return defaults when absent."
  [config-path]
  (if (nil? (os/stat config-path))
    (prepare-command-config {})
    (do
      (unless (= :file (os/stat config-path :mode))
        (error (string config-path " is not a file")))
      (try
        (prepare-command-config (parse (slurp config-path)))
        ([err] (error (string config-path ": " err)))))))

(defn commands-for-config
  "Return all commands from prepared configuration."
  [config]
  (merge (built-in-commands (config :settings) (config :jobs))
         (config :commands)))

(defn available-commands
  "Return built-in commands merged with the configured custom commands."
  []
  (if-let [config-path (command-config-path)]
    (commands-for-config (load-command-config config-path))
    (built-in-commands)))

(defn- command-list
  ``Render the commands for the top-level help. argparse documents named
  options only, never positionals, so the command list has to be carried in
  the description it prints.``
  [commands]
  (string/join
    (seq [name :in (sort (keys commands))]
      (string/format "  %-10s%s" name (get-in commands [name :help])))
    "\n"))

(defn main
  [& args]
  (def commands
    (try
      (available-commands)
      ([err]
        (eprint "Configuration error: " err)
        (os/exit 1))))
  (def spec
    [(string "manage multiple git/jj repositories\n\n Commands:\n"
             (command-list commands))
     "version" {:kind :flag
                :short "V"
                :help "Show the version and exit."}
     :default {:kind :accumulate
               :short-circuit true
               :help "Command to run."}])
  (def parsed (parse-args args ;spec))
  (when (parsed "version")
    (print "herd " version)
    (os/exit 0))
  # :rest starts at the command name, which the subcommand parser then reads as
  # its own program name, so `herd clone --help` describes clone.
  (def rest (or (parsed :rest) @[]))
  (if-let [command (get commands (first rest))]
    ((command :run) rest)
    (do
      (if (empty? rest)
        # Naming no command is still a usage error, but a bare usage line
        # hides what the commands do, so show the same help `--help` prints.
        (argparse/argparse ;spec :args [(get args 0 "herd") "--help"])
        (eprint "Unknown command \"" (first rest) "\""))
      (os/exit 1))))
