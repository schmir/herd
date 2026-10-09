(import spork/argparse)
(import spork/path)
(import ./checkout)
(import ./clone)
(import ./completions)
(import ./config)
(import ./discover)
(import ./parallel)
(import ./run)
(import ./select)
(import ./survey)

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

(defn- version-requested?
  ``Whether `args` asks for the version. Only the very first argument can: the
  flag carries no value, and whatever follows it is either a command name,
  which owns its own options, or a mistake. Everything else is left to
  argparse, which owns the usage errors and the help text.``
  [args]
  (def arg (get args 1))
  (cond
    (nil? arg) false
    # --version=VALUE is left to argparse, so that it rejects the value.
    (string/has-prefix? "--" arg) (= "--version" arg)
    # A cluster of short flags asks for the version only when that is all it
    # asks for: -hV wants the help argparse prints, and -Vx is a mistake.
    (and (string/has-prefix? "-" arg) (> (length arg) 1))
    (all (fn [character] (= character (chr "V"))) (string/slice arg 1))
    false))

(def- help-option
  ``A plain flag standing in for the help option argparse adds itself. Its
  own stops parsing at the first h, and reports any mistake after it as help
  or not at all, so -hx would succeed. As a plain flag it lets every other
  option be checked first, and a mistake anywhere wins over the help.``
  {:kind :flag
   :short "h"
   :help "Show this help message."})

(defn- flag-given-value
  ``The name of the first flag `args` hands a value with --name=VALUE, or nil.
  argparse accepts the form for a flag and then drops the value, so
  --all-anchors=no would turn the flag on. The scan follows argparse through
  `args`: an option given as --name or in a cluster of short flags takes the
  next argument as its value, and options end at `--` or, where the
  positional arguments stop parsing, at the first of those.``
  [args options]
  (def shorts (tabseq [[name handler] :pairs options
                       :when (handler :short)]
                ((handler :short) 0) name))
  (defn takes-value? [name]
    (index-of (get-in options [name :kind]) [:option :accumulate]))
  (var i 1)
  (var found nil)
  (while (and (nil? found) (< i (length args)))
    (def arg (args i))
    (++ i)
    (cond
      (= "--" arg) (break)
      (string/has-prefix? "--" arg)
      (let [[name & value] (string/split "=" (string/slice arg 2))]
        (cond
          (empty? value) (when (takes-value? name) (++ i))
          (= :flag (get-in options [name :kind])) (set found name)))
      (string/has-prefix? "-" arg)
      (each flag (string/slice arg 1)
        (when (takes-value? (shorts flag)) (++ i)))
      (get-in options [:default :short-circuit]) (break)))
  found)

(defn- exit-on-error
  "Return what `attempt` returns, or print `label` and the error and exit 1."
  [label attempt]
  (try
    (attempt)
    ([err]
      (eprint label err)
      (os/exit 1))))

(defn- parse-args
  ``Parse `args` against an argparse specification, exiting on a mistake.
  Asking for help is not a mistake, so it leaves through the successful door.``
  [args & spec]
  (def with-help [;spec "help" help-option])
  (def parsed (or (argparse/argparse ;with-help :args args)
                  (os/exit 1)))
  (when-let [name (flag-given-value args (struct ;(slice with-help 1)))]
    (eprint "usage error: --" name " is a flag and takes no value")
    (os/exit 1))
  (when (parsed "help")
    # Only argparse's own help option prints the text, so ask it for that.
    (argparse/argparse ;spec :args [(get args 0) "--help"])
    (os/exit 0))
  parsed)

(defn- filter-names
  "The filter names `parsed` was given on the command line, in order."
  [parsed]
  (or (parsed "filter") []))

(defn- rest-arguments
  "The positional arguments `parsed` collected, starting at the command."
  [parsed]
  (or (parsed :rest) @[]))

(defn- filters-in-play?
  ``Whether any filter narrows this run, named on the command line or by a
  checkout row. An empty result is worth explaining only when something could
  have removed the repositories.``
  [names settings]
  (or (not (empty? names))
      (not (empty? (get-in settings [:defaults :filter] [])))
      (true? (some (fn [checkout] (not (empty? (get checkout :filter []))))
                   (get settings :checkouts [])))))

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

(defn- read-configuration
  ``Load the configured repositories, exiting on a configuration error. The
  filters named in `names` narrow every configuration file further, on top of
  whatever its checkout rows already filter. Return the repositories with the
  directory and the configuration files they were read from.``
  [settings names]
  (require-known-filters names settings)
  (def directory (config/config-directory))
  (when (nil? directory)
    (eprint "Neither XDG_CONFIG_HOME nor HOME is set, so there is no "
            "configuration directory to read")
    (os/exit 1))
  (def config-paths
    (exit-on-error "Configuration error: "
                   (fn [] (config/discover-config-files directory))))
  # Validate checkout sources even when no repository lists exist.
  (def repositories
    (exit-on-error "Configuration error: "
                   (fn [] (config/load-config config-paths directory settings
                                              names))))
  {:directory directory :paths config-paths :repositories repositories})

(defn- exit-unconfigured
  ``Say that `loaded` read no configuration files, and exit successfully.
  Nothing configured yet is a normal state, not a failure: exiting non-zero
  would make `just run` print a traceback over an unremarkable message.``
  [loaded]
  (eprint "No configuration files in " (loaded :directory))
  (os/exit 0))

(defn- select-configured
  ``Select the repositories in `config` at a path. Unless `quiet` is set,
  say why the result is empty.``
  [at all-anchors config settings names &opt quiet]
  (def anchors (unless all-anchors (select/containing-anchors at config)))
  (def selected
    (select/select-repositories-with-anchors at config all-anchors anchors))
  # Say why the result is empty. Since --at defaults to the current
  # directory, standing in the wrong place otherwise looks like a broken
  # configuration.
  (when (and (empty? selected) (not quiet))
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

(defn- configured-repositories
  ``Load the configured repositories and select the ones at a path. The
  filters named in `names` narrow every configuration file further, on top of
  whatever its checkout rows already filter.``
  [at all-anchors &opt settings names]
  (default settings config/default-repository-settings)
  (def loaded (read-configuration settings names))
  (when (empty? (loaded :paths))
    (exit-unconfigured loaded))
  (select-configured at all-anchors (loaded :repositories) settings names))

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
  (def parsed (scan-number count))
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
  (exit-on-error "Invalid --jobs: " (fn [] (scan-jobs (parsed "jobs")))))

(defn- selected-repositories
  "Load the repositories `parsed` selects: its --at, --all-anchors and --filter."
  [parsed settings]
  (configured-repositories (parsed "at") (parsed "all-anchors") settings
                           (filter-names parsed)))

(defn- exit-unless-complete
  ``Leave with the interrupt exit code when the run was interrupted, and with 1
  when `failed`. An interrupted run reached only part of the list, so it
  cannot report success however well the part it reached went.``
  [failed]
  (when (parallel/interrupted?)
    (os/exit parallel/interrupt-exit-code))
  (when failed
    (os/exit 1)))

(defn clone-command
  "Run herd clone with each repository's configured VCS."
  [args &opt settings jobs]
  (def parsed
    (parse-selection args
                     "Check out the configured repositories beneath a path."
                     "jobs" (jobs-option jobs)))
  (def jobs (parsed-jobs parsed))
  (def repositories (selected-repositories parsed settings))
  (def counts (clone/clone-repositories repositories jobs))
  (print (counts :cloned) " cloned, "
         (counts :skipped) " already checked out, "
         (counts :blocked) " blocked, "
         (counts :failed) " failed")
  # A blocked repository was asked for and is still not checked out.
  (exit-unless-complete (pos? (+ (counts :failed) (counts :blocked)))))

(def- discovery-options
  "The list options that shape the scan of the disk, by name."
  ["max-depth" "hidden" "follow-links"])

(defn- scan-max-depth
  ``Return the depth --max-depth names, nil when it is not given, or raise a
  descriptive error.``
  [depth]
  (unless (nil? depth)
    (def parsed (scan-number depth))
    (unless (and (int? parsed) (>= parsed 0))
      (error "expected a non-negative integer"))
    parsed))

(defn- extra-on-disk
  ``Scan the disk from `at` and return the repositories no configuration file
  defines, whatever their anchor or the filters named on the command line.
  A checkout row's own filter does count: a repository it leaves out is not
  meant to be there.``
  [parsed settings names configured]
  (def max-depth
    (exit-on-error "Invalid --max-depth: "
                   (fn [] (scan-max-depth (parsed "max-depth")))))
  (def everything
    (if (empty? names)
      configured
      ((read-configuration settings []) :repositories)))
  (def root (survey/scan-root (parsed "at")))
  # Selection accepts a path that is not a directory, such as a repository
  # not cloned yet, and there is nothing beneath it to scan.
  (def discovered
    (if (= :directory (os/stat root :mode))
      (discover/find-repositories root
                                  :max-depth max-depth
                                  :hidden (parsed "hidden")
                                  :follow-links (parsed "follow-links"))
      @[]))
  (survey/extra-repositories discovered everything))

(defn list-command
  ``Run `herd list`: print the selected repositories, one tab-separated path
  and URL per line, in the order the commands act on them. --ok, --missing
  and --extra pick what to print by comparing them with what is on disk,
  and print the extra ones after the configured ones. Without them, plain
  list prints every configured repository, and --status what differs.``
  [args &opt settings]
  (default settings config/default-repository-settings)
  (def parsed
    (parse-selection args "Print the configured repositories beneath a path."
                     "ok" {:kind :flag
                           :help "Print configured repositories that are on disk."}
                     "missing" {:kind :flag
                                :help "Print configured repositories that are not on disk."}
                     "extra" {:kind :flag
                              :help "Print repositories on disk that no configuration defines."}
                     "status" {:kind :flag
                               :help (string "Print the status of each repository first: "
                                             "ok, missing, blocked, or extra. "
                                             "Without --ok, --missing or --extra, "
                                             "print only what differs.")}
                     "max-depth" {:kind :option
                                  :value-name "N"
                                  :help "Scan at most N directories below the path for extra repositories."}
                     "hidden" {:kind :flag
                               :help "Scan hidden directories for extra repositories."}
                     "follow-links" {:kind :flag
                                     :help "Follow symbolic links when scanning for extra repositories."}))
  (def names (filter-names parsed))
  (def status (parsed "status"))
  (def picked (or (parsed "ok") (parsed "missing") (parsed "extra")))
  # The ok repositories are what --status leaves out unless asked: it is
  # there to show what differs.
  (def want-ok (if picked (parsed "ok") (not status)))
  (def want-missing (if picked (parsed "missing") true))
  (def scan (if picked (parsed "extra") status))
  (unless scan
    (when-let [name (find parsed discovery-options)]
      (eprint "usage error: --" name " applies only when extra "
              "repositories are listed, by --extra or a plain --status")
      (os/exit 1)))
  (def show-configured (or want-ok want-missing))
  (def loaded (read-configuration settings names))
  (when (and (empty? (loaded :paths)) (not scan))
    (exit-unconfigured loaded))
  (def configured (loaded :repositories))
  (def selected
    (if show-configured
      # Explaining an empty selection would mislead when the disk is
      # scanned as well, since that can still turn up repositories.
      (select-configured (parsed "at") (parsed "all-anchors") configured
                         settings names scan)
      @[]))
  (defn emit [state & fields]
    (print ;(if status [state "\t"] []) (string/join fields "\t")))
  (each entry selected
    (def state (if (and want-ok want-missing (not status))
                 "ok"
                 (checkout/checkout-status entry)))
    (when (if (= "ok" state) want-ok want-missing)
      (emit state (entry :path) (entry :ssh_url))))
  (when scan
    (each repository (extra-on-disk parsed settings names configured)
      (emit "extra" (repository :path)
            (or (survey/remote-url repository) "")))))

(defn- run-configured-command
  "Run a command in the selected repositories and report its outcome."
  [command parsed &opt settings]
  (def show-output
    (exit-on-error "Invalid --show-output: "
                   (fn [] (run/require-show-output (parsed "show-output")))))
  (def jobs (parsed-jobs parsed))
  (def repositories (selected-repositories parsed settings))
  (def counts (run/run-in-repositories command repositories show-output jobs))
  (print (counts :succeeded) " succeeded, "
         (counts :failed) " failed, "
         (counts :skipped) " skipped, "
         (counts :not-checked-out) " not checked out")
  (exit-unless-complete (pos? (counts :failed))))

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
  (def command (rest-arguments parsed))
  (when (empty? command)
    (eprint "herd run needs a command")
    (os/exit 1))
  (run-configured-command command parsed settings))

(defn completions-command
  ``Run `herd completions`: print the script for a shell, or, for the scripts
  to call back, the commands in effect including any configured ones, which
  `commands` returns.``
  [args commands]
  (def parsed
    (parse-args args
                "Print a shell completion script for herd."
                :default {:kind :accumulate
                          :short-circuit true
                          :help (string "Shell to write for: "
                                        (string/join completions/shells ", ") ".")}))
  (def rest (rest-arguments parsed))
  (def script
    (when (= 1 (length rest))
      (completions/script (first rest))))
  (cond
    (deep= (tuple ;rest) ["commands"]) (print (completions/command-lines (commands)))
    script (prin script)
    (do (eprint "herd completions needs one of: "
                (string/join completions/shells ", "))
      (os/exit 1))))

(defn built-in-commands
  ``Subcommands by name, with their argument handler and one-line summary.
  The config's per-file settings and job count are bound here so every
  handler starts from them, leaving the command line to override.``
  [config]
  (def {:settings settings :jobs jobs} config)
  {"clone" {:run (fn [args] (clone-command args settings jobs))
            :help "Check out the configured repositories beneath a path."}
   "completions" {:run (fn [args]
                         (completions-command
                           args
                           (fn [] (merge (built-in-commands config)
                                         (config :commands)))))
                  :help "Print a shell completion script for herd."}
   "list" {:run (fn [args] (list-command args settings))
           :help "Print the configured repositories beneath a path."}
   "run" {:run (fn [args] (run-command args jobs settings))
          :help "Run a command in each configured repository beneath a path."}})

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

(def built-in-command-names
  "Names of the built-in subcommands, which a custom command may not reuse."
  ["clone" "completions" "list" "run"])

(def custom-command-keys
  "Keys a custom-command definition may contain."
  [:command :command-git :command-jj :description :show-output])

(def default-command-definitions
  ``Custom commands herd defines itself, written as they would be in :commands
  of config.jdn. A definition of the same name there replaces one.``
  {"diff" {:command-git "git diff HEAD"
           :command-jj "jj diff"
           :description "Show working copy changes in configured repositories beneath a path."
           :show-output "always"}
   "fetch" {:command-git "git fetch"
            :command-jj "jj git fetch"
            :description "Fetch Git remotes in configured repositories beneath a path."}})

(defn command-from-definition
  "Validate one custom-command definition and return its :command, :description, and :show-output."
  [name definition]
  (unless (and (string? name) (not (empty? name)))
    (error "custom command names must be non-empty strings"))
  (defn fail [message]
    (error (string "custom command \"" name "\" " message)))
  (when (index-of name built-in-command-names)
    (fail "conflicts with a built-in command"))
  (unless (dictionary? definition)
    (fail "must be a dictionary"))
  (eachk key definition
    (unless (index-of key custom-command-keys)
      (fail (string "has an unknown key " (describe key)))))
  (def command (get definition :command))
  (def command-git (get definition :command-git))
  (def command-jj (get definition :command-jj))
  (def resolved
    (if (not (nil? command))
      (do
        (unless (string? command)
          (fail "needs a string :command"))
        (when (or (not (nil? command-git)) (not (nil? command-jj)))
          (fail "cannot combine :command with VCS-specific commands"))
        command)
      (do
        (when (and (nil? command-git) (nil? command-jj))
          (fail "needs :command, :command-git, or :command-jj"))
        (unless (or (nil? command-git) (string? command-git))
          (fail "needs a string :command-git"))
        (unless (or (nil? command-jj) (string? command-jj))
          (fail "needs a string :command-jj"))
        {:command-git command-git :command-jj command-jj})))
  (def description (get definition :description))
  (unless (string? description)
    (fail "needs a string :description"))
  (def show-output (get definition :show-output run/default-show-output))
  (try
    (run/require-show-output show-output)
    ([err]
      (fail (string "has an invalid :show-output; " err))))
  {:command resolved :description description :show-output show-output})

(defn prepare-command-config
  "Validate raw JDN configuration and construct its command handlers."
  [config]
  (def jobs (configured-jobs config))
  (def settings (config/configured-repository-settings config))
  (def configured (get config :commands {}))
  (unless (dictionary? configured)
    (error ":commands must be a dictionary"))
  (def commands @{})
  (eachp [name definition] (merge default-command-definitions configured)
    (def {:command command :description description :show-output show-output}
      (command-from-definition name definition))
    (put commands name
         {:run (make-run-command command description show-output jobs settings)
          :help description}))
  {:settings settings
   :jobs jobs
   :commands commands})

(defn load-command-config
  "Read and validate JDN configuration, or return defaults when absent."
  [config-path]
  (def stat (os/stat config-path))
  (cond
    (nil? stat) (prepare-command-config {})
    (not= :file (stat :mode)) (error (string config-path " is not a file"))
    (try
      (prepare-command-config (config/parse-settings (slurp config-path)))
      ([err] (error (string config-path ": " err))))))

(defn available-commands
  "Return built-in commands merged with the configured custom commands."
  []
  (def config
    (if-let [config-path (command-config-path)]
      (load-command-config config-path)
      (prepare-command-config {})))
  (merge (built-in-commands config) (config :commands)))

(defn- command-list
  ``Render the commands for the top-level help. argparse documents named
  options only, never positionals, so the command list has to be carried in
  the description it prints.``
  [commands]
  (string/join
    (seq [name :in (sort (keys commands))]
      (string/format "  %-12s%s" name (get-in commands [name :help])))
    "\n"))

(defn main
  [& args]
  # Answered before the configuration is read, so a broken one cannot stop it.
  (when (version-requested? args)
    (print "herd " version)
    (os/exit 0))
  (def commands
    (exit-on-error "Configuration error: " available-commands))
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
  # :rest starts at the command name, which the subcommand parser then reads as
  # its own program name, so `herd clone --help` describes clone.
  (def rest (rest-arguments parsed))
  (if-let [command (get commands (first rest))]
    ((command :run) rest)
    (do
      (if (empty? rest)
        # Naming no command is still a usage error, but a bare usage line
        # hides what the commands do, so show the same help `--help` prints.
        (argparse/argparse ;spec :args [(get args 0 "herd") "--help"])
        (eprint "Unknown command \"" (first rest) "\""))
      (os/exit 1))))
