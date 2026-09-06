(import spork/argparse)
(import spork/json)
(import spork/path)
(import ./parallel)

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

(defn clone-repository
  ``Clone a Git repository unless it is already checked out.
  Returns :skipped, :cloned or :failed.``
  [jj env report path url]
  (if (checked-out? path)
    :skipped
    (try
      (do
        (def process (os/spawn [jj "git" "clone" "--colocate" url path] : env))
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
  ``Clone repositories, keeping at most `worker-count` Git processes active.
  Returns a struct of :cloned, :skipped and :failed counts.``
  [repositories]
  (def jj (find-executable "jj"))
  (def total (length repositories))
  (if (nil? jj)
    (do
      (eprint "jj was not found on PATH")
      {:cloned 0 :skipped 0 :failed total})
    # Clones must never inherit the terminal: several run at once, and a jj
    # or ssh prompt on a shared stdin would interleave or hang the whole run.
    (with [devnull (file/open "/dev/null" :r)]
      (def env {:in devnull :out :pipe :err :pipe})
      (parallel/run-repositories
        repositories
        [[:cloned "cloned"]
         [:skipped "already checked out"]
         [:failed "failed"]]
        (fn [repository report]
          (clone-repository jj env report
                            (repository :path)
                            (repository :ssh_url)))))))

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
        (error (string "entry " index " needs a string \"" key "\"")))))
  config)

(defn parse-config
  "Parse JSON source into application configuration."
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

(defn config-files
  ``Configuration files in `directory`, sorted so the merge order is stable.
  A missing directory yields none: having no configuration yet is normal.``
  [directory]
  (def names (if directory (try (os/dir directory) ([_] @[])) @[]))
  (sort (seq [name :in names
              :when (string/has-suffix? ".json" name)
              :let [file (path/join directory name)]
              :when (= :file (os/stat file :mode))]
          file)))

(defn config-anchor
  ``Directory the relative paths in config-path are joined to. A .root symlink
  beside a file in the configuration directory overrides the usual anchor.``
  [config-path directory]
  (def parent (path/parent (os/realpath config-path)))
  (def configuration
    (when directory (try (os/realpath directory) ([_] nil))))
  (def visible-parent (os/realpath (path/parent config-path)))
  (def in-configuration (and configuration (= visible-parent configuration)))
  (def root-path (string config-path ".root"))
  (def root-mode (when in-configuration (os/lstat root-path :mode)))
  (cond
    root-mode
    (do
      (unless (= :link root-mode)
        (error (string root-path " must be a symlink to a directory")))
      (def root
        (try
          (os/realpath root-path)
          ([err]
            (error (string "cannot resolve " root-path ": " err)))))
      (unless (= :directory (os/stat root :mode))
        (error (string root-path " must point to a directory")))
      root)

    (and configuration (= parent configuration))
    (or (os/getenv "HOME") parent)

    true parent))

(defn resolve-repository-paths
  ``Return the entries with every relative path joined to anchor. Paths
  coming from different files are only comparable once they are absolute.``
  [entries anchor]
  (with-dyns [:path-cwd anchor]
    (seq [entry :in entries]
      (merge entry {:path (path/abspath (entry :path))
                    :anchors @[anchor]}))))

(defn read-config
  "Read, parse and validate one configuration file, resolving its paths."
  [config-path directory]
  (resolve-repository-paths
    (validate-config (parse-config (slurp config-path)))
    (config-anchor config-path directory)))

(defn merge-configs
  ``Concatenate `[config-path entries]` pairs into one repository list. Two
  files may name the same checkout only when they agree on the URL; letting
  them disagree would make the result depend on the reading order.``
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
                                   :anchors (entry :anchors)})
          (array/push merged entry))

        (not= (previous :ssh_url) (entry :ssh_url))
        (error (string/format "%s and %s disagree on the URL for %s"
                              (previous :source) config-path (entry :path)))

        true
        (each anchor (entry :anchors)
          (unless (some |(= anchor $) (previous :anchors))
            (array/push (previous :anchors) anchor))))))
  merged)

(defn load-config
  ``Read every configuration file and merge them into one repository list.
  Errors name the file they came from, since a bad entry is otherwise hard to
  place once several files are in play.``
  [config-paths directory]
  (merge-configs
    (seq [config-path :in config-paths]
      [config-path
       (try
         (read-config config-path directory)
         ([err] (error (string config-path ": " err))))])))

(defn- bare-path
  ``Drop trailing slashes, which normalisation keeps but comparison must not.``
  [path]
  (def trimmed (string/trimr path "/"))
  (if (empty? trimmed) "/" trimmed))

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
  (def root (bare-path (path/abspath path)))
  (def found @[])
  (each repository repositories
    (each anchor (get repository :anchors [])
      (def candidate (bare-path (path/abspath anchor)))
      (when (and (holds-path? candidate root)
                 (not (some |(= candidate $) found)))
        (array/push found candidate))))
  found)

(defn select-repositories-with-anchors
  "Filter repositories with anchors that were already selected."
  [path repositories all-anchors anchors]
  (def root (bare-path (path/abspath path)))
  (filter (fn [repository]
            (def candidate (bare-path (repository :path)))
            (and (or all-anchors
                     (some (fn [repository-anchor]
                             (def normalized
                               (bare-path (path/abspath repository-anchor)))
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
  [at all-anchors]
  (def directory (config-directory))
  (when (nil? directory)
    (eprint "Neither XDG_CONFIG_HOME nor HOME is set, so there is no "
            "configuration directory to read")
    (os/exit 1))
  (def config-paths (config-files directory))
  # Nothing configured yet is a normal state, not a failure: exiting non-zero
  # would make `just run` print a traceback over an unremarkable message.
  (when (empty? config-paths)
    (eprint "No configuration files in " directory)
    (os/exit 0))
  (def config
    (try
      (load-config config-paths directory)
      ([err]
        (eprint "Configuration error: " err)
        (os/exit 1))))
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

(defn- selected-repositories
  "Parse the selection arguments shared by clone and list."
  [args description]
  (def parsed
    (parse-args args description
                "at" (at-option)
                "all-anchors" (all-anchors-option)))
  (configured-repositories (parsed "at")
                           (parsed "all-anchors")))

(defn clone-command
  ``Run `herd clone`: check out the repositories the arguments select.``
  [args]
  (def repositories
    (selected-repositories args
                           "Check out the configured repositories beneath a path."))
  (def counts (clone-repositories repositories))
  (print (counts :cloned) " cloned, "
         (counts :skipped) " already checked out, "
         (counts :failed) " failed")
  (when (pos? (counts :failed))
    (os/exit 1)))

(defn list-command
  ``Run `herd list`: print the selected repositories, one tab-separated path
  and URL per line, in the order the commands act on them.``
  [args]
  (each entry (selected-repositories args
                                     "Print the configured repositories beneath a path.")
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

(defn run-in-repository
  "Run and capture a command in a repository without changing herd's cwd."
  [command env repository report &opt show-output]
  (try
    (if (checked-out? (repository :path))
      (with [process
             (os/spawn ["sh" "-c" `cd "$1" && shift && exec "$@"`
                        "herd" (repository :path) ;command]
                       :p env)]
        (def stdout @"")
        (def stderr @"")
        (ev/gather
          (:read (process :out) :all stdout)
          (:read (process :err) :all stderr)
          (:wait process))
        (def status (process :return-code))
        (def succeeded (zero? status))
        (when (or (not succeeded)
                  (and show-output
                       (or (pos? (length stdout))
                           (pos? (length stderr)))))
          (report (format-command-result repository status stdout stderr)))
        (if succeeded :succeeded :failed))
      :not-checked-out)
    ([err]
      (report "✗ " (repository :path) "\n"
              (indent-command-output (string err)))
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
  [command repositories &opt show-output]
  # Parallel commands must not share a terminal for input or output. Capture
  # output per process so each visible result is one coherent block.
  (with [devnull (file/open "/dev/null" :r)]
    (def env {:in devnull :out :pipe :err :pipe})
    (def report-state @{:reported false})
    (parallel/run-repositories
      repositories
      [[:succeeded "succeeded"]
       [:failed "failed"]
       [:not-checked-out "not checked out"]]
      (fn [repository report]
        (run-in-repository command env repository
                           |(report-command-result report-state report ;$&)
                           show-output)))))

(defn- run-configured-command
  "Run a command in the selected repositories and report its outcome."
  [command parsed]
  (def repositories
    (configured-repositories (parsed "at") (parsed "all-anchors")))
  (def counts (run-in-repositories command repositories
                                   (parsed "show-output")))
  (print (counts :succeeded) " succeeded, "
         (counts :failed) " failed, "
         (counts :not-checked-out) " not checked out")
  (when (pos? (counts :failed))
    (os/exit 1)))

(defn make-run-command
  "Return a handler that uses description for help and runs command."
  [command description]
  (fn [args]
    (def parsed
      (parse-args args description
                  "at" (at-option)
                  "all-anchors" (all-anchors-option)
                  "show-output" {:kind :flag
                                 :help "Show output from successful commands."}))
    (run-configured-command command parsed)))

(defn run-command
  "Run herd run with the command and repository selection in args."
  [args]
  (def parsed
    (parse-args args
                (string "Run a command in each configured repository beneath a path.\n\n"
                        " Usage: herd run [option] ... CMD [CMD-ARGS]...")
                "at" (at-option)
                "all-anchors" (all-anchors-option)
                "show-output" {:kind :flag
                               :help "Show output from successful commands."}
                :default {:kind :accumulate
                          :short-circuit true
                          :help "Command and arguments to run."}))
  (def command (or (parsed :rest) @[]))
  (when (empty? command)
    (eprint "herd run needs a command")
    (os/exit 1))
  (run-configured-command command parsed))

(def commands
  ``Subcommands by name. Each carries the function to run, given the arguments
  from the command name onwards, and a one-line summary.``
  {"clone" {:run clone-command
            :help "Check out the configured repositories beneath a path."}
   "fetch" {:run (make-run-command
                    ["jj" "git" "fetch"]
                    "Fetch Git remotes in each configured repository beneath a path.")
            :help "Fetch Git remotes in configured repositories beneath a path."}
   "list" {:run list-command
           :help "Print the configured repositories beneath a path."}
   "run" {:run run-command
          :help "Run a command in each configured repository beneath a path."}})

(defn- command-list
  ``Render the commands for the top-level help. argparse documents named
  options only, never positionals, so the command list has to be carried in
  the description it prints.``
  []
  (string/join
    (seq [name :in (sort (keys commands))]
      (string/format "  %-10s%s" name (get-in commands [name :help])))
    "\n"))

(defn main
  [& args]
  (def parsed
    (parse-args args
                (string "manage multiple git/jj repositories\n\n Commands:\n"
                        (command-list))
                :default {:kind :accumulate
                          :short-circuit true
                          :help "Command to run."}))
  # :rest starts at the command name, which the subcommand parser then reads as
  # its own program name, so `herd clone --help` describes clone.
  (def rest (or (parsed :rest) @[]))
  (if-let [command (get commands (first rest))]
    ((command :run) rest)
    (do
      (if (empty? rest)
        (eprint "usage: herd " (string/join (sort (keys commands)) "|") " [option] ...")
        (eprint "Unknown command \"" (first rest) "\""))
      (os/exit 1))))
