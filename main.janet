(import spork/argparse)
(import spork/json)
(import spork/path)
(import spork/rawterm)

(def worker-count
  "Number of Git processes allowed to run at the same time."
  6)

(def spinner-frames
  "Frames cycled through beside each in-flight clone."
  ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"])

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

(defn terminal-width
  "Usable terminal columns, falling back to 80 when the size is unknown."
  []
  (def [_ columns] (try (rawterm/size) ([_] [0 0])))
  (if (< 20 columns 1000) columns 80))

(defn make-progress
  ``State backing the live display. It only draws when stderr is a terminal,
  so redirected output stays plain.``
  [total]
  @{:total total
    :active @{}
    :cloned 0
    :skipped 0
    :failed 0
    :frame 0
    :drawn 0
    :running true
    :live (os/isatty stderr)})

(defn- erase
  "Remove the drawn block, leaving the cursor where it began."
  [progress]
  (when (pos? (progress :drawn))
    (eprinf "\e[%dA\e[J" (progress :drawn))
    (put progress :drawn 0)))

(defn- fit-path
  ``Trim path to `width` columns. Repository paths share long leading
  segments, so drop those first and keep the distinguishing tail.``
  [path width]
  (def segments (string/split "/" path))
  (var text path)
  (var index 0)
  (while (and (> (rawterm/monowidth text) width)
              (< (inc index) (length segments)))
    (++ index)
    (set text (string "…/" (string/join (slice segments index) "/"))))
  (if (> (rawterm/monowidth text) width)
    (string (rawterm/slice-monowidth text width))
    text))

(defn- draw
  "Repaint the block: one line per busy worker, then a tally."
  [progress]
  (when (progress :live)
    (erase progress)
    # Truncate to one column short of the edge so no line wraps; a wrapped
    # line would make the cursor-up count in `erase` wrong.
    (def width (dec (terminal-width)))
    (def frame (spinner-frames (% (progress :frame) (length spinner-frames))))
    (def lines @[])
    (for slot 0 worker-count
      (when-let [path (get (progress :active) slot)]
        (array/push lines (string frame " " (fit-path path (- width 2))))))
    (array/push lines
                (string (rawterm/slice-monowidth
                          (string/format "%d/%d  %d cloned  %d already checked out  %d failed"
                                         (+ (progress :cloned) (progress :skipped) (progress :failed))
                                         (progress :total)
                                         (progress :cloned)
                                         (progress :skipped)
                                         (progress :failed))
                          width)))
    (each line lines
      (eprin line)
      (eprin "\n"))
    (put progress :drawn (length lines))
    (file/flush stderr)))

(defn- log
  "Write a line above the block, then redraw it."
  [progress & xs]
  (erase progress)
  (eprint ;xs)
  (draw progress))

(defn- animate
  "Cycle the spinner until the run finishes."
  [progress]
  (when (progress :live)
    (ev/spawn
      (while (progress :running)
        (ev/sleep 0.08)
        # :running may have been cleared while this fiber slept. Drawing after
        # the final erase would strand a stale block below the summary.
        (when (progress :running)
          (update progress :frame inc)
          (draw progress))))))

(defn checked-out?
  "Check whether path already holds a checkout."
  [path]
  (and (= :directory (os/stat path :mode))
       (not (empty? (os/dir path)))))

(defn checkout
  ``Clone a Git repository unless it is already checked out.
  Returns :skipped, :cloned or :failed.``
  [jj env progress path url]
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
              (log progress "Checkout complete: " path)
              :cloned)
            (do
              (log progress "Checkout failed: " path)
              (when (> (length stderr) 0) (log progress stderr))
              (when (> (length stdout) 0) (log progress stdout))
              :failed)))
      ([err]
        (log progress "Checkout failed: " path ": " err)
        :failed))))

(defn checkout-all
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
      (def progress (make-progress total))
      (def cursor @[0])
      # Each worker claims the next index and moves on as soon as its own
      # clone finishes. Reading and advancing the cursor never yields, so
      # no two workers can claim the same index.
      (defn worker [slot]
        (while (< (cursor 0) total)
          (def index (cursor 0))
          (put cursor 0 (inc index))
          (def repository (repositories index))
          (put (progress :active) slot (repository :path))
          (draw progress)
          (def result (checkout jj env progress
                                (repository :path)
                                (repository :ssh_url)))
          (put (progress :active) slot nil)
          (update progress result inc)))
      (animate progress)
      (ev/go-gather (seq [slot :range [0 worker-count]] |(worker slot)))
      (put progress :running false)
      (erase progress)
      (file/flush stderr)
      {:cloned (progress :cloned)
       :skipped (progress :skipped)
       :failed (progress :failed)})))

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
  ``Directory the relative paths in `config-path` are joined to. Symlinks are
  resolved first, so a file linked into the configuration directory anchors at
  its real location; a file that truly lives in the configuration directory
  anchors at the home directory instead, that directory being no place for
  checkouts.``
  [config-path directory]
  (def parent (path/parent (os/realpath config-path)))
  (def configuration
    (when directory (try (os/realpath directory) ([_] nil))))
  (if (and configuration (= parent configuration))
    (or (os/getenv "HOME") parent)
    parent))

(defn absolute-paths
  ``Return the entries with every relative :path joined to `anchor`. Paths
  coming from different files are only comparable once they are absolute.``
  [entries anchor]
  (with-dyns [:path-cwd anchor]
    (seq [entry :in entries]
      (merge entry {:path (path/abspath (entry :path))}))))

(defn read-config
  "Read, parse and validate one configuration file, resolving its paths."
  [config-path directory]
  (absolute-paths (validate-config (parse-config (slurp config-path)))
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
          (put seen (entry :path) {:source config-path :ssh_url (entry :ssh_url)})
          (array/push merged entry))

        (not= (previous :ssh_url) (entry :ssh_url))
        (error (string/format "%s and %s disagree on the URL for %s"
                              (previous :source) config-path (entry :path))))))
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

(defn select-repositories
  ``Repositories that `path` selects: the ones checked out beneath it, and the
  one it is checked out inside. Naming a directory therefore selects
  everything below it, and standing anywhere within a working copy selects
  that repository, however deep. A relative path is taken from the current
  directory, matching how a shell would read it.``
  [path repositories]
  (def root (bare-path (path/abspath path)))
  (filter (fn [repository]
            (def candidate (bare-path (repository :path)))
            (or (holds-path? root candidate)
                (holds-path? candidate root)))
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

(defn- selected-config
  ``Parse the arguments shared by every command that reads configuration, and
  return the repositories it selects. Files named on the command line replace
  the ones in the configuration directory rather than adding to them, and
  --under narrows the result to one subtree, defaulting to the current
  directory so that a command acts on the checkout you are standing in.``
  [args description]
  (def parsed
    (parse-args args description
                "under" {:kind :option
                         :short "u"
                         :value-name "PATH"
                         :default (os/cwd)
                         :help "Only act on repositories beneath PATH, or the one PATH is inside."}
                :default {:kind :accumulate
                          :help "Configuration files to read instead of the ones in the configuration directory."}))
  (def given (or (parsed :default) @[]))
  (def directory (config-directory))
  (when (and (empty? given) (nil? directory))
    (eprint "Neither XDG_CONFIG_HOME nor HOME is set, so there is no "
            "configuration directory to read")
    (os/exit 1))
  (def config-paths (if (empty? given) (config-files directory) given))
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
  (def under (parsed "under"))
  (def selected (select-repositories under config))
  # Say why the result is empty. Since --under defaults to the current
  # directory, standing in the wrong place otherwise looks like a broken
  # configuration.
  (when (and (empty? selected) (not (empty? config)))
    (eprint "None of the " (length config) " configured repositories are beneath " under
            " or hold it"))
  selected)

(defn clone-command
  ``Run `herd clone`: check out the repositories the arguments select.``
  [args]
  (def config
    (selected-config args "Check out the configured repositories beneath a path."))
  (def counts (checkout-all config))
  (print (counts :cloned) " cloned, "
         (counts :skipped) " already checked out, "
         (counts :failed) " failed")
  (when (pos? (counts :failed))
    (os/exit 1)))

(defn list-command
  ``Run `herd list`: print the selected repositories, one tab-separated path
  and URL per line, in the order the commands act on them.``
  [args]
  (each entry (selected-config args "Print the configured repositories beneath a path.")
    (print (entry :path) "\t" (entry :ssh_url))))

(def commands
  ``Subcommands by name. Each carries the function to run, given the arguments
  from the command name onwards, and a one-line summary.``
  {"clone" {:run clone-command
            :help "Check out the configured repositories beneath a path."}
   "list" {:run list-command
           :help "Print the configured repositories beneath a path."}})

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
