# The herd command line: argument parsing and the subcommands.

(import spork/argparse)
(import ./arguments)
(import ./checkout)
(import ./clone)
(import ./completions)
(import ./config)
(import ./discover)
(import ./filter)
(import ./options)
(import ./parallel)
(import ./process)
(import ./run)
(import ./selection)
(import ./survey)

(defmacro- baked-version
  ``The version named by HERD_VERSION, read while this file is compiled.
  Baking it in is what makes a downloaded binary able to say which release it
  is: looking the variable up at run time would only describe the machine the
  binary ended up on. A build that names no version is not a release.``
  []
  (def requested (os/getenv "HERD_VERSION"))
  (if (or (nil? requested) (empty? requested)) "dev" requested))

(def version
  "Version this build was compiled for."
  (baked-version))

(defn- argparse-option
  "The argparse specification of the declared `option`, with its default from `defaults`."
  [option defaults]
  (def spec @{:kind (option :kind) :help (option :help)})
  (each key [:short :value-name]
    (when (option key)
      (put spec key (option key))))
  (when-let [default (get defaults (option :name))]
    (put spec :default default))
  (table/to-struct spec))

(defn- spec-entries
  ``The argparse entries, name and specification in turn, of the declared
  `options`. The help option is left out: parse-args adds its own.``
  [options defaults]
  (def entries @[])
  (each option options
    (unless (= "help" (option :name))
      (array/push entries (option :name) (argparse-option option defaults))))
  entries)

(defn command-spec
  ``The argparse entries of the options `command` takes, as options declares
  them. `defaults` holds the defaults only the program knows, by option name.``
  [command defaults]
  (spec-entries (options/for-command command) defaults))

(def- help-option
  ``A plain flag standing in for the help option argparse adds itself. Its
  own stops parsing at the first h, and reports any mistake after it as help
  or not at all, so -hx would succeed. As a plain flag it lets every other
  option be checked first, and a mistake anywhere wins over the help.``
  (argparse-option (find (fn [option] (= "help" (option :name))) options/top-level)
                   {}))

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
  (when-let [name (arguments/flag-given-value args (struct ;(slice with-help 1)))]
    (eprint "usage error: --" name " is a flag and takes no value")
    (os/exit 1))
  (when (parsed "help")
    # Only argparse's own help option prints the text, so ask it for that.
    (argparse/argparse ;spec :args [(get args 0) "--help"])
    (os/exit 0))
  parsed)

(defn- rest-arguments
  "The positional arguments `parsed` collected, starting at the command."
  [parsed]
  (or (parsed :rest) @[]))

(defn- describe-filters
  "Name the filters in play, for a message about an empty selection."
  [names]
  (string (if (= 1 (length names)) "filter " "filters ")
          (string/join (map describe names) " and ")))

(defn- exit-unconfigured
  ``Say that `catalog` read no repository lists, and exit successfully.
  Nothing configured yet is a normal state, not a failure: exiting non-zero
  would make `just run` print a traceback over an unremarkable message.``
  [catalog]
  (eprint "No repository lists in " (catalog :directory))
  (os/exit 0))

(defn- resolve-filters
  "Sort what `parsed` was given with -f, as selection/resolve-filters does."
  [parsed repository-settings]
  (selection/resolve-filters (or (parsed "filter") []) repository-settings))

(defn- explain-empty
  ``Say why `reason` says a selection is empty. Unless the reason is that the
  state or the shell commands emptied it, `quiet?` leaves it out: where the
  disk is searched as well, an empty selection would mislead, since the
  discovery can still turn up repositories.``
  [reason quiet?]
  # Since --at defaults to the current directory, standing in the wrong place
  # otherwise looks like a broken configuration.
  (case (get reason :kind)
    :emptied-by-state
    (eprint "No repository is left of the " (reason :of)
            " selected by "
            (string/join [;(if (reason :wanted) [(string "--" (reason :wanted))] [])
                          ;(if (reason :commands?) ["-f"] [])]
                         " and "))

    :emptied-by-filters
    # Filtering can empty the configuration itself, before the location is
    # ever weighed, so say that rather than blaming the location.
    (unless quiet?
      (eprint "No configured repository is left by "
              (if (empty? (reason :names))
                (string "the filters in " config/settings-file-name)
                (describe-filters (reason :names)))))

    :no-anchor-contains-path
    (unless quiet?
      (eprint "No configuration anchor contains " (reason :at-path)
              "; use -a/--all-anchors to consider every anchor"))

    :none-beneath-path
    (unless quiet?
      (eprint "None of the configured repositories under the selected "
              "anchors are beneath " (reason :at-path) " or contain it"))))

(defn- exit-unless-complete
  ``Leave with the interrupt exit code when `result`, of a run or a selection,
  says it was interrupted, and with 1 when `failed?`. An interrupted run
  reached only part of the list, so it cannot report success however well the
  part it reached went.``
  [result failed?]
  (when (result :interrupted?)
    (os/exit parallel/interrupt-exit-code))
  (when failed?
    (os/exit 1)))

(defn- select-repositories
  ``Select the repositories `options` ask for, as selection/select does, and
  report for the CLI what stops the run or explains an empty selection. With
  `unconfigured-ok?`, a configuration directory without files does not end the
  run, and with `quiet?`, explanations of a selection the location emptied are
  left out.``
  [options repository-settings &named unconfigured-ok? quiet?]
  (def result
    (try
      (selection/select options repository-settings)
      ([err]
        (if (dictionary? err)
          (eprint "Selection error: " (err :stage-error))
          (eprint "Configuration error: " err))
        (os/exit 1))))
  (exit-unless-complete result false)
  (def reason (result :reason))
  (case (get reason :kind)
    :mistyped-filter
    # A single word that no program on PATH answers to was most likely a
    # filter name with a typo in it, which is better said now than found out
    # as a command that fails in every checkout, or never runs where nothing
    # is checked out.
    (do
      (eprint (describe (reason :value))
              " is neither a configured filter nor a command"
              (if (empty? (reason :known))
                "; no filters are configured"
                (string "; configured filters are "
                        (string/join (map describe (reason :known)) ", "))))
      (os/exit 1))

    :no-config-directory
    (do
      (eprint "Neither XDG_CONFIG_HOME nor HOME is set, so there is no "
              "configuration directory to read")
      (os/exit 1))

    :unconfigured
    (unless unconfigured-ok?
      (exit-unconfigured (result :catalog)))

    (explain-empty reason quiet?))
  result)

(defn- parse-jobs
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

(defn- parse-command
  ``Parse `args` with the options `command` declares, and `rest`, a
  specification for what follows them, if any. `defaults` adds to --at, which
  defaults to the working directory.``
  [args command description defaults & rest]
  (parse-args args description
              ;(command-spec command (merge {"at" (os/cwd)} defaults))
              ;rest))

(defn- jobs-from
  "Return the validated --jobs count, or report the mistake and exit."
  [parsed]
  (exit-on-error "Invalid --jobs: " (fn [] (parse-jobs (parsed "jobs")))))

(defn- selection-options
  "The selection options `parsed` holds: where, from which anchors, and by which -f."
  [parsed]
  {:at-path (parsed "at")
   :all-anchors? (parsed "all-anchors")
   :filter-values (or (parsed "filter") [])})

(defn- wanted-state
  "The state --dirty or --clean asks for, or nil. Asking for both is a mistake."
  [parsed]
  (when (and (parsed "dirty") (parsed "clean"))
    (eprint "usage error: --dirty and --clean exclude each other")
    (os/exit 1))
  (cond
    (parsed "dirty") :dirty
    (parsed "clean") :clean))

(defn clone-command
  "Run herd clone with each repository's configured VCS."
  [args &opt repository-settings jobs]
  (def parsed
    (parse-command args "clone"
                   "Check out the configured repositories beneath a path."
                   {"jobs" (string (or jobs parallel/default-jobs))}))
  (def jobs (jobs-from parsed))
  (def selection (resolve-filters parsed repository-settings))
  # A shell command needs a checkout to run in, and clone is what makes them.
  (when-let [value (first (selection :command-values))]
    (eprint "usage error: clone can only use the JMESPath filters in :filters, "
            "and " (describe value) " is not one")
    (os/exit 1))
  (def repositories
    ((select-repositories (selection-options parsed) repository-settings) :repositories))
  (def result (clone/clone-repositories repositories jobs))
  (print (result :summary))
  # A blocked repository was asked for and is still not checked out.
  (exit-unless-complete
    result (pos? (+ ((result :counts) :failed) ((result :counts) :blocked)))))

(def- discovery-options
  "The list options that shape the discovery on disk, by name."
  ["max-depth" "hidden" "follow-links"])

(defn- parse-max-depth
  ``Return the depth --max-depth names, nil when it is not given, or raise a
  descriptive error.``
  [depth]
  (unless (nil? depth)
    (def parsed (scan-number depth))
    (unless (and (int? parsed) (>= parsed 0))
      (error "expected a non-negative integer"))
    parsed))

(defn- discover-extra
  ``Discover repositories on disk from `--at` and return the ones no
  repository list defines, whatever their anchor or the filters named on the
  command line. A checkout row's own filter does count: a repository it
  leaves out is not meant to be there.``
  [parsed repository-settings names configured]
  (def max-depth
    (exit-on-error "Invalid --max-depth: "
                   (fn [] (parse-max-depth (parsed "max-depth")))))
  (def everything
    (if (empty? names)
      configured
      (((select-repositories {:catalog-only? true} repository-settings) :catalog)
        :repositories)))
  (def root (survey/discover-root (parsed "at")))
  # Selection accepts a path that is not a directory, such as a repository
  # not cloned yet, and there is nothing beneath it to discover.
  (def discovered
    (if (= :directory (os/stat root :mode))
      (discover/find-repositories root
                                  :max-depth max-depth
                                  :hidden? (parsed "hidden")
                                  :follow-links? (parsed "follow-links"))
      @[]))
  (survey/extra-repositories discovered everything))

(defn list-command
  ``Run `herd list`: print the selected repositories, one tab-separated path
  and URL per line, in the order the commands act on them. --ok, --missing
  and --extra pick what to print by comparing them with what is on disk,
  and print the extra ones after the configured ones. Without them, plain
  list prints every configured repository, and --status what differs.``
  [args &opt repository-settings]
  (default repository-settings config/default-repository-settings)
  (def parsed
    (parse-command args "list"
                   "Print the configured repositories beneath a path." {}))
  (def wanted (wanted-state parsed))
  (def show-status? (parsed "status"))
  (def picked? (or (parsed "ok") (parsed "missing") (parsed "extra")))
  # The ok repositories are what --status leaves out unless asked: it is
  # there to show what differs.
  (def want-ok? (if picked? (parsed "ok") (not show-status?)))
  (def want-missing? (if picked? (parsed "missing") true))
  (def discover? (if picked? (parsed "extra") show-status?))
  (unless discover?
    (when-let [name (find parsed discovery-options)]
      (eprint "usage error: --" name " applies only when extra "
              "repositories are listed, by --extra or a plain --status")
      (os/exit 1)))
  (def show-configured? (or want-ok? want-missing?))
  # Explaining an empty selection would mislead when the disk is searched as
  # well, since that can still turn up repositories. The disk discovery needs
  # the catalog, but a list of only the extra repositories selects none from it.
  (def result
    (select-repositories
      (merge (selection-options parsed)
             {:wanted-state wanted
              :jobs parallel/default-jobs
              :catalog-only? (not show-configured?)})
      repository-settings
      :unconfigured-ok? discover?
      :quiet? discover?))
  (def configured ((result :catalog) :repositories))
  (def selected (result :repositories))
  (defn emit [status & fields]
    (print ;(if show-status? [status "\t"] []) (string/join fields "\t")))
  (each repository selected
    (def status (if (and want-ok? want-missing? (not show-status?))
                  :ok
                  (checkout/checkout-status repository)))
    (when (if (= :ok status) want-ok? want-missing?)
      (emit status (repository :path) (repository :ssh_url))))
  (when discover?
    (each repository (discover-extra parsed repository-settings ((result :filters) :names) configured)
      (emit "extra" (repository :path)
            (or (survey/remote-url repository) "")))))

(defn- run-selected
  "Run a command in the selected repositories and report its outcome."
  [command parsed &opt repository-settings]
  (def wanted (wanted-state parsed))
  (def show-output
    (exit-on-error "Invalid --show-output: "
                   (fn [] (run/require-show-output (parsed "show-output")))))
  (def jobs (jobs-from parsed))
  (def repositories
    ((select-repositories
       (merge (selection-options parsed)
              {:wanted-state wanted
               :jobs jobs})
       repository-settings)
      :repositories))
  (def result (run/run-in-repositories repositories command show-output jobs))
  (print (result :summary))
  (exit-unless-complete result (pos? ((result :counts) :failed))))

(defn custom-command-handler
  "Return a handler that uses description for help and runs command."
  [command description &opt show-output jobs repository-settings]
  (def show-output (or show-output run/default-show-output))
  (fn [args]
    (def parsed
      (parse-command args "run" description
                     {"show-output" show-output
                      "jobs" (string (or jobs parallel/default-jobs))}))
    (run-selected command parsed repository-settings)))

(defn run-command
  "Run herd run with the command and repository selection in args."
  [args &opt jobs repository-settings]
  (def parsed
    (parse-command args "run"
                   (string "Run a command in each configured repository beneath a path.\n\n"
                           " Usage: herd run [option] ... CMD [CMD-ARGS]...")
                   {"show-output" run/default-show-output
                    "jobs" (string (or jobs parallel/default-jobs))}
                   :default {:kind :accumulate
                             :short-circuit true
                             :help "Command and arguments to run."}))
  (def command (rest-arguments parsed))
  (when (empty? command)
    (eprint "herd run needs a command")
    (os/exit 1))
  (run-selected command parsed repository-settings))

(defn completions-command
  ``Run `herd completions`: print the script for a shell, or, for the scripts
  to call back, the subcommands in effect including any configured ones, which
  `subcommands` returns, or the configured filters, which `filters` returns.``
  [args subcommands filters]
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
    (deep= (tuple ;rest) ["commands"]) (print (completions/subcommand-lines (subcommands)))
    (deep= (tuple ;rest) ["filters"]) (print (completions/filter-lines (filters)))
    script (prin script)
    (do (eprint "herd completions needs one of: "
                (string/join completions/shells ", "))
      (os/exit 1))))

(defn custom-commands
  "Build the handler of each custom command that `config` holds."
  [config]
  (def {:settings repository-settings :jobs jobs :commands definitions} config)
  (tabseq [[name {:command command :description description
                  :show-output show-output}] :pairs definitions]
    name {:run (custom-command-handler command description show-output jobs repository-settings)
          :help description}))

(defn built-in-subcommands
  ``Subcommands by name, with their argument handler and one-line summary.
  The loaded config's per-file settings and job count are bound here so
  every handler starts from them, leaving the command line to override.``
  [config]
  (def {:settings repository-settings :jobs jobs} config)
  {"clone" {:run (fn [args] (clone-command args repository-settings jobs))
            :help "Check out the configured repositories beneath a path."}
   "completions" {:run (fn [args]
                         (completions-command
                           args
                           (fn [] (merge (built-in-subcommands config)
                                         (custom-commands config)))
                           (fn [] (filter/descriptions (get repository-settings :filters {})))))
                  :help "Print a shell completion script for herd."}
   "list" {:run (fn [args] (list-command args repository-settings))
           :help "Print the configured repositories beneath a path."}
   "run" {:run (fn [args] (run-command args jobs repository-settings))
          :help "Run a command in each configured repository beneath a path."}})

(def built-in-subcommand-names
  "Names of the built-in subcommands, which a custom command may not reuse."
  (keys (built-in-subcommands {})))

(defn available-subcommands
  "Return built-in subcommands merged with the configured custom commands."
  []
  (def config
    (config/load-settings (config/config-directory) built-in-subcommand-names))
  (merge (built-in-subcommands config) (custom-commands config)))

(defn- subcommand-list
  ``Render the subcommands for the top-level help. argparse documents named
  options only, never positionals, so the command list has to be carried in
  the description it prints.``
  [subcommands]
  (string/join
    (seq [name :in (sort (keys subcommands))]
      (string/format "  %-12s%s" name (get-in subcommands [name :help])))
    "\n"))

(defn main
  [& args]
  # Answered before the configuration is read, so a broken one cannot stop it.
  (when (arguments/version-requested? args)
    (print "herd " version)
    (os/exit 0))
  (def subcommands
    (exit-on-error "Configuration error: " available-subcommands))
  (def spec
    [(string "manage multiple git/jj repositories\n\n Commands:\n"
             (subcommand-list subcommands))
     ;(spec-entries options/top-level {})
     :default {:kind :accumulate
               :short-circuit true
               :help "Command to run."}])
  (def parsed (parse-args args ;spec))
  # :rest starts at the command name, which the subcommand parser then reads as
  # its own program name, so `herd clone --help` describes clone.
  (def rest (rest-arguments parsed))
  (if-let [subcommand (get subcommands (first rest))]
    ((subcommand :run) rest)
    (do
      (if (empty? rest)
        # Naming no command is still a usage error, but a bare usage line
        # hides what the subcommands do, so show the same help `--help` prints.
        (argparse/argparse ;spec :args [(get args 0 "herd") "--help"])
        (eprint "Unknown command \"" (first rest) "\""))
      (os/exit 1))))
