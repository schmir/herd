# The options of the herd command line, each declared once.

(def- help
  {:name "help" :short "h" :kind :flag :help "Show this help message."})

(def- at
  {:name "at" :short "C" :kind :option :value-name "PATH"
   :help "Select repositories using PATH as the working location."})

(def- all-anchors
  {:name "all-anchors" :short "a" :kind :flag
   :help "Consider repositories from every configuration anchor."})

(def- filter-option
  {:name "filter" :short "f" :kind :accumulate :value-name "NAME"
   :help "Select only repositories kept by the named filter."})

(def- jobs
  {:name "jobs" :short "j" :kind :option :value-name "N"
   :help "Run at most N repository operations at the same time."})

(def- show-output
  {:name "show-output" :kind :option :value-name "WHEN"
   :help "Show command output: never, on-failure, or always."})

(def- dirty
  {:name "dirty" :kind :flag
   :help "Select only repositories with uncommitted changes."})

(def- clean
  {:name "clean" :kind :flag
   :help "Select only checked-out repositories without uncommitted changes."})

(def- list-only
  [{:name "ok" :kind :flag
    :help "Print configured repositories that are on disk."}
   {:name "missing" :kind :flag
    :help "Print configured repositories that are not on disk."}
   {:name "extra" :kind :flag
    :help "Print repositories on disk that no configuration defines."}
   {:name "status" :kind :flag
    :help (string "Print the status of each repository first: "
                  "ok, missing, blocked, or extra. "
                  "Without --ok, --missing or --extra, "
                  "print only what differs.")
    :summary "Print the status of each repository first."}
   {:name "max-depth" :kind :option :value-name "N"
    :help "Discover extra repositories at most N directories below the path."}
   {:name "hidden" :kind :flag
    :help "Include hidden directories when discovering extra repositories."}
   {:name "follow-links" :kind :flag
    :help "Follow symbolic links when discovering extra repositories."}])

(def- list-repositories
  {:name "repositories" :short "r" :kind :flag
   :help "List the repositories."})

(def top-level
  "The options of bare herd."
  [help
   {:name "version" :short "V" :kind :flag
    :help "Show the version and exit."}])

(defn for-command
  ``The options `command` takes, in the order its help lists them. A command
  the configuration defines runs a command in each repository, so anything that
  is not built in takes what `herd run` does apart from the command itself.``
  [command]
  (def selecting [at all-anchors filter-option help])
  (case command
    "clone" [;selecting jobs]
    "list" [;selecting ;list-only dirty clean]
    "completions" [help]
    "tree" [help list-repositories]
    [;selecting show-output jobs dirty clean]))
