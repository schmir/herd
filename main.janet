(import spork/argparse)
(import spork/path)
(import ./clone)
(import ./config)
(import ./parallel)
(import ./run)
(import ./select)

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

(defn- filters-in-play?
  ``Whether any filter narrows this run, named on the command line or by a
  checkout row. An empty result is worth explaining only when something could
  have removed the repositories.``
  [names settings]
  (or (not (empty? names))
      (not (empty? (get-in settings [:defaults :filter] [])))
      (true? (some (fn [rows]
                     (some |(not (empty? (get $ :filter []))) rows))
                   (values (get settings :rows {}))))))

(defn- describe-filters
  "Name the filters in play, for a message about an empty selection."
  [names]
  (string (if (= 1 (length names)) "filter " "filters ")
          (string/join (map describe names) " and ")))

(defn- require-known-filters
  ``Report and exit when `names` holds a filter `settings` does not define.
  Checked before anything is read, so a typo does not look like a list that
  simply matched nothing.``
  [names settings]
  (def filters (get settings :filters {}))
  (each name names
    (unless (get filters name)
      (eprint "Unknown filter " (describe name)
              (if (empty? filters)
                "; no filters are configured"
                (string "; configured filters are "
                        (string/join (map describe (sort (keys filters)))
                                     ", "))))
      (os/exit 1))))

(defn- configured-repositories
  ``Load the configured repositories and select the ones at a path. The
  filters named in `names` narrow every configuration file further, on top of
  whatever its checkout rows already filter.``
  [at all-anchors &opt settings names]
  (default settings config/default-repository-settings)
  (default names [])
  (require-known-filters names settings)
  (def directory (config/config-directory))
  (when (nil? directory)
    (eprint "Neither XDG_CONFIG_HOME nor HOME is set, so there is no "
            "configuration directory to read")
    (os/exit 1))
  (def config-paths
    (try
      (config/discover-config-files directory)
      ([err]
        (eprint "Configuration error: " err)
        (os/exit 1))))
  # Validate checkout sources even when no repository lists exist.
  (def config
    (try
      (config/load-config config-paths directory settings names)
      ([err]
        (eprint "Configuration error: " err)
        (os/exit 1))))
  # Nothing configured yet is a normal state, not a failure: exiting non-zero
  # would make `just run` print a traceback over an unremarkable message.
  (when (empty? config-paths)
    (eprint "No configuration files in " directory)
    (os/exit 0))
  (def anchors (unless all-anchors (select/containing-anchors at config)))
  (def selected
    (select/select-repositories-with-anchors at config all-anchors anchors))
  # Say why the result is empty. Since --at defaults to the current
  # directory, standing in the wrong place otherwise looks like a broken
  # configuration.
  (when (empty? selected)
    (cond
      # Filtering can empty the configuration itself, before the location is
      # ever weighed, so say that rather than blaming the location.
      (and (empty? config) (filters-in-play? names settings))
      (eprint "No configured repository is left by "
              (if (empty? names)
                "the filters in config.jdn"
                (describe-filters names)))

      (empty? config) nil

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

(defn- filter-option
  ``The --filter specification, shared by every selecting command. Repeating
  it pipes one filter into the next, after whatever the checkout rows filter.``
  []
  {:kind :accumulate
   :short "f"
   :value-name "NAME"
   :help "Select only repositories kept by the named filter."})

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

(defn- scan-jobs
  ``Return the job count `count` names, or raise a descriptive error. It
  arrives from the command line as a string, and is weighed against the range
  parallel/run-repositories accepts, so an out-of-range count fails here with
  a message instead of there with a stack trace.``
  [count]
  (def parsed (if (string? count) (scan-number count) count))
  (unless (parallel/jobs? parsed)
    (error (string "expected a positive integer no greater than "
                   parallel/max-jobs)))
  parsed)

(defn- parse-selection
  "Parse the selection arguments shared by every selecting command."
  [args description & spec]
  (parse-args args description
              "at" (at-option)
              "all-anchors" (all-anchors-option)
              "filter" (filter-option)
              ;spec))

(defn- parsed-jobs
  "Return the validated --jobs count, or report the mistake and exit."
  [parsed]
  (try
    (scan-jobs (parsed "jobs"))
    ([err]
      (eprint "Invalid --jobs: " err)
      (os/exit 1))))

(defn- selected-repositories
  "Parse the selection arguments and load the repositories they select."
  [args description settings]
  (def parsed (parse-selection args description))
  (configured-repositories (parsed "at")
                           (parsed "all-anchors")
                           settings
                           (or (parsed "filter") [])))

(defn clone-command
  "Run herd clone with each repository's configured VCS."
  [args &opt settings jobs]
  (def parsed
    (parse-selection args
                     "Check out the configured repositories beneath a path."
                     "jobs" (jobs-option jobs)))
  (def jobs (parsed-jobs parsed))
  (def repositories
    (configured-repositories (parsed "at") (parsed "all-anchors") settings
                             (or (parsed "filter") [])))
  (def counts (clone/clone-repositories repositories jobs))
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

(defn- run-configured-command
  "Run a command in the selected repositories and report its outcome."
  [command parsed &opt settings]
  (def show-output
    (try
      (run/require-show-output (parsed "show-output"))
      ([err]
        (eprint "Invalid --show-output: " err)
        (os/exit 1))))
  (def jobs (parsed-jobs parsed))
  (def repositories
    (configured-repositories (parsed "at") (parsed "all-anchors") settings
                             (or (parsed "filter") [])))
  (def counts (run/run-in-repositories command repositories show-output jobs))
  (print (counts :succeeded) " succeeded, "
         (counts :failed) " failed, "
         (counts :skipped) " skipped, "
         (counts :not-checked-out) " not checked out")
  (when (pos? (counts :failed))
    (os/exit 1)))

(defn make-run-command
  "Return a handler that uses description for help and runs command."
  [command description &opt show-output jobs settings]
  (def show-output (or show-output run/default-show-output))
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
                     "show-output" (show-output-option run/default-show-output)
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
  (default settings config/default-repository-settings)
  (default jobs parallel/default-jobs)
  {"clone" {:run (fn [args] (clone-command args settings jobs))
            :help (built-in-command-help "clone")}
   "fetch" {:run (make-run-command
                   {:command-git "git fetch"
                    :command-jj "jj git fetch"}
                   "Fetch Git remotes in each configured repository beneath a path."
                   run/default-show-output
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
  (when-let [directory (config/config-directory)]
    (path/join directory "config.jdn")))

(defn configured-jobs
  "Return the configured job count, or the default when it is not set."
  [config]
  (unless (dictionary? config)
    (error "expected a JDN dictionary"))
  (def jobs (get config :jobs parallel/default-jobs))
  (unless (parallel/jobs? jobs)
    (error (string ":jobs must be a positive integer no greater than "
                   parallel/max-jobs)))
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
    (def show-output (get definition :show-output run/default-show-output))
    (try
      (run/require-show-output show-output)
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
  (def settings (config/configured-repository-settings config))
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
