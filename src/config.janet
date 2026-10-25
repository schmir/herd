# Reading the configuration directory into the repositories it describes.

(import spork/json)
(import spork/path)
(import ./checkout)
(import ./named-filters)
(import ./parallel)
(import ./run)
(import ./vcs)

(defn config-directory
  ``Directory holding the JSON repository lists and the settings file,
  or nil when neither XDG_CONFIG_HOME nor HOME is set.``
  []
  (if-let [xdg (os/getenv "XDG_CONFIG_HOME")]
    (path/join xdg "herd")
    (when-let [home (os/getenv "HOME")]
      (path/join home ".config" "herd"))))

(def settings-file-name
  "File in the configuration directory holding the settings and commands."
  "config.jdn")

(def repository-list-suffix ".json")

(defn discover-repository-lists
  ``Repository lists in `directory`, sorted so the merge order is stable.
  A directory that is not there yields none: having no configuration yet is
  normal. One that cannot be listed for any other reason raises instead of
  passing for empty, since a directory herd cannot read holds every
  repository it would otherwise report as gone.``
  [directory]
  # Only an absent directory is quiet, and nothing but the listing can say
  # that it is absent: os/stat cannot reach a directory under a closed
  # parent either, and reports that as nil with no reason attached, exactly
  # as it reports one that was never created.
  (def names
    (if directory
      (try (os/dir directory)
        ([err] (if (string/has-suffix? "No such file or directory"
                                       (string err))
                 @[]
                 (error err))))
      @[]))
  (sort (seq [name :in names
              :when (string/has-suffix? repository-list-suffix name)
              :let [file (path/join directory name)]
              :when (= :file (os/stat file :mode))]
          file)))

(def checkout-row-keys
  "Non-option keys that a checkout row can contain."
  [:from :anchor :filter :strip-components])

(defn- reject-unknown-setting
  "Raise for a setting that is not configurable."
  [where key known]
  (unless (index-of key known)
    (error (string where " has an unknown setting " (describe key)))))

(defn- validate-anchor-setting
  ``Validate an optional anchor as a non-empty string. `:defaults` may also
  hold `false`, which leaves a list no row anchors without any anchor. It is
  not `nil` because a dictionary cannot hold one.``
  [settings where &opt allow-none?]
  (def anchor (get settings :anchor :unset))
  (unless (or (= :unset anchor) (and allow-none? (= false anchor)))
    (unless (and (string? anchor) (not (empty? anchor)))
      (error (string where " needs a non-empty :anchor"
                     (if allow-none? " or false" "")))))
  settings)

(defn- validate-filter-setting
  ``Validate an optional `:filter` as an array of filter names. It is always
  an array, even for a single name, so there is one shape to write and one to
  read. An empty array filters nothing, which is how a row drops the filters
  it would otherwise inherit from `:defaults`.``
  [settings where]
  (def names (get settings :filter :unset))
  (unless (= :unset names)
    (unless (indexed? names)
      (error (string where " needs an array of filter names in :filter")))
    (each name names
      (unless (and (string? name) (not (empty? name)))
        (error (string where " names an invalid filter " (describe name)
                       "; expected a non-empty string")))))
  settings)

(defn- validate-strip-components-setting
  "Validate an optional component count as a non-negative integer."
  [settings where]
  (when (has-key? settings :strip-components)
    (def strip-count (settings :strip-components))
    (unless (and (int? strip-count) (not (neg? strip-count)))
      (error (string where
                     " needs a non-negative integer in :strip-components"))))
  settings)

(defn validate-checkout-row
  ``Validate one `:checkouts` row and return it. Each row must name a
  repository list.``
  [checkout-row where]
  (unless (dictionary? checkout-row)
    (error (string where " must be a dictionary")))
  (eachk key checkout-row
    (reject-unknown-setting where key [;checkout-row-keys ;checkout/option-keys]))
  (def from (get checkout-row :from))
  (unless (and (string? from) (not (empty? from)))
    (error (string where " needs a :from naming a repository list")))
  (validate-anchor-setting checkout-row where)
  (validate-filter-setting checkout-row where)
  (validate-strip-components-setting checkout-row where)
  (checkout/validate-repository-options checkout-row where)
  checkout-row)

(defn validate-checkout-defaults
  "Validate `:defaults` and return them. Defaults cannot name a source."
  [defaults]
  (unless (dictionary? defaults)
    (error ":defaults must be a dictionary"))
  (eachk key defaults
    (reject-unknown-setting ":defaults" key [:anchor :filter ;checkout/option-keys]))
  (validate-anchor-setting defaults ":defaults" true)
  (validate-filter-setting defaults ":defaults")
  (checkout/validate-repository-options defaults ":defaults")
  defaults)

(defn parse-settings-file
  ``Return the one settings value `source` holds, or an empty one when it
  holds none. Holding several is a mistake rather than a file to read the
  first of: settings appended as a second dictionary, rather than merged into
  the one already there, would otherwise be dropped without a word.``
  [source]
  (def parsed (parse-all source))
  (case (length parsed)
    0 {}
    1 (parsed 0)
    (error (string "expected one dictionary of settings, but the file holds "
                   (length parsed) " top-level values"))))

(def default-repository-settings
  "Repository settings used when the settings file is absent."
  {:defaults {} :checkouts [] :filters {}})

(defn configured-repository-settings
  ``Validate repository settings. The checkout rows keep the order they were
  written in.``
  [settings-file]
  (unless (dictionary? settings-file)
    (error "expected a JDN dictionary"))
  (def rows (get settings-file :checkouts []))
  (unless (indexed? rows)
    (error ":checkouts must be an array of rows"))
  (def checkout-rows
    (seq [index :range [0 (length rows)]]
      (validate-checkout-row (rows index)
                             (string ":checkouts row " index))))
  (def filters (named-filters/validate-registry (get settings-file :filters {})))
  (def defaults (validate-checkout-defaults (get settings-file :defaults {})))
  (named-filters/require-list-filters filters (get defaults :filter []) ":defaults")
  (each checkout-row checkout-rows
    (named-filters/require-list-filters filters (get checkout-row :filter [])
                                        (string ":checkouts row for "
                                                (describe (checkout-row :from)))))
  {:defaults defaults
   :checkouts checkout-rows
   :filters filters})

(defn checkout-rows-for-list
  ``Merge each checkout row of `name` with the defaults. Return the defaults alone
  when none names the file.``
  [settings name]
  (def defaults (get settings :defaults {}))
  (def matching
    (filter (fn [checkout-row] (= (checkout-row :from) name))
            (get settings :checkouts [])))
  (if (empty? matching)
    @[(merge defaults)]
    (map (fn [checkout-row] (merge defaults checkout-row)) matching)))

(defn- repository-options
  "Return only the repository options set in `source`."
  [source]
  (def options @{})
  (each key checkout/option-keys
    (def value (get source key))
    (unless (nil? value)
      (put options key value)))
  options)

(defn resolve-checkout-rows
  ``Resolve each checkout row into a placement: its anchor resolved to a
  directory, with its repository options, filter and strip count. Relative
  anchors use HOME, and so does a missing anchor. Both fail without it, and a
  default anchor of false fails outright. Keep configured paths because
  selection resolves symbolic links.``
  [list-path checkout-rows]
  (def name (path/basename list-path))
  (seq [checkout-row :in checkout-rows]
    (def anchor (get checkout-row :anchor))
    (def resolved
      (cond
        (or (nil? anchor) (= false anchor))
        (if (= false anchor)
          (error (string "cannot place " name
                         ": the default anchor is disabled"))
          (or (os/getenv "HOME")
              (error (string "cannot place " name " without HOME"))))

        (path/abspath? anchor)
        (path/abspath anchor)

        (if-let [home (os/getenv "HOME")]
          (with-dyns [:path-cwd home]
            (path/abspath anchor))
          (error (string "cannot resolve relative anchor for "
                         name " without HOME")))))
    (merge (repository-options checkout-row)
           {:path resolved
            :filter (get checkout-row :filter [])
            :strip-components (get checkout-row :strip-components 0)})))

(defn- strip-path-components
  ``Remove `strip-count` leading components and return a relative path. The
  `anchor` only names the row in the error, since a file read under several
  anchors strips a different number of components under each.``
  [listed-path strip-count anchor]
  (if (zero? strip-count)
    listed-path
    (let [components (filter (fn [component] (not (empty? component)))
                             (path/parts (path/normalize listed-path)))]
      (when (>= strip-count (length components))
        (error (string "the row anchored at " (describe anchor)
                       " cannot strip " strip-count " components from path "
                       (describe listed-path) "; no components remain")))
      (string/join (drop strip-count components) path/sep))))

(defn resolve-repository-paths
  ``Resolve each entry once per placement, stripping its leading components and
  applying its repository options. Entries without placements produce no
  checkouts. Unstripped absolute paths remain the same under all placements so
  `merge-repository-lists` can combine them.``
  [entries placements]
  (def resolved @[])
  (each placement placements
    (def options (repository-options placement))
    (with-dyns [:path-cwd (placement :path)]
      (each entry entries
        (def listed-path
          (strip-path-components (entry :path)
                                 (get placement :strip-components 0)
                                 (placement :path)))
        # Apply options from least to most specific: defaults, placement, entry.
        (def settled (merge checkout/default-repository-options options entry))
        (array/push resolved
                    (merge settled
                           {:vcs (vcs/parse (settled :vcs))
                            :path (path/abspath listed-path)
                            :anchors @[(placement :path)]})))))
  resolved)

(defn validate-repository-list
  ``Return the `entries` of a repository list unchanged, or raise an error
  describing their shape.``
  [entries]
  (unless (indexed? entries)
    (error "expected a JSON array of repository objects"))
  (for index 0 (length entries)
    (def entry (entries index))
    (unless (dictionary? entry)
      (error (string "entry " index " is not a JSON object")))
    (each key [:path :ssh_url]
      (unless (string? (entry key))
        (error (string "entry " index " needs a string \"" key "\""))))
    (checkout/validate-repository-options entry (string "entry " index) `"vcs"`))
  entries)

(defn read-repository-list
  ``Read one repository list, resolving each repository into checkouts.
  A row filters before its anchor is applied, so each row can describe a
  different part of the same list, and `names` narrows every row further.
  Only the entries a filter kept are validated: a list may carry entries herd
  could not use, which is the point of filtering it. The file is decoded once,
  after the filters have had it, so what they see is the file itself.``
  [list-path checkout-rows &opt filters names]
  (default filters {})
  (default names [])
  (def source (slurp list-path))
  (def placements (resolve-checkout-rows list-path checkout-rows))
  (def resolved @[])
  # Rows sharing a chain are the common case, so filter once for each distinct
  # chain rather than once for every anchor. The chain itself is the key: a
  # filter name is an arbitrary string, so joining names into one would let
  # two different chains spell the same key and hand a row the repositories
  # another row had selected.
  (def selected @{})
  (each placement placements
    (def chain [;(placement :filter) ;names])
    (def kept
      (if (has-key? selected chain)
        (get selected chain)
        # A row aimed its own filters at this file; the command line aimed
        # its filters at every file, so only those need to explain themselves.
        (let [computed (validate-repository-list
                         (json/decode
                           (named-filters/narrow filters source (placement :filter) names)
                           true))]
          (put selected chain computed)
          computed)))
    (array/concat resolved (resolve-repository-paths kept [placement])))
  resolved)

(defn merge-repository-lists
  ``Concatenate `[list-path repositories]` pairs into one repository list.
  Two files may name the same checkout only when they agree on the URL and on
  every repository option; letting them disagree would make the result depend
  on the reading order.``
  [lists]
  (def seen @{})
  (def merged @[])
  (each [list-path repositories] lists
    (each repository repositories
      (def previous (get seen (repository :path)))
      # Weigh whichever options there are rather than naming one of them, so
      # that a repository option added later is compared without this having to
      # be remembered and revisited.
      (def disagreement
        (when previous
          (find (fn [key]
                  (not= (get-in previous [:options key]) (get repository key)))
                checkout/option-keys)))
      (cond
        (nil? previous)
        (do
          (put seen (repository :path)
               {:source list-path
                :ssh_url (repository :ssh_url)
                :options (repository-options repository)
                :anchors (repository :anchors)})
          (array/push merged repository))

        (not= (previous :ssh_url) (repository :ssh_url))
        (error (string/format "%s and %s disagree on the URL for %s"
                              (previous :source) list-path (repository :path)))

        disagreement
        (error (string/format "%s and %s disagree on the %s for %s"
                              (previous :source) list-path disagreement
                              (repository :path)))

        true
        (each anchor (repository :anchors)
          (unless (some (fn [known] (= anchor known)) (previous :anchors))
            (array/push (previous :anchors) anchor))))))
  merged)

(defn- reject-unknown-sources
  ``Reject checkouts whose source file is missing. This prevents a
  renamed list from silently using the defaults.``
  [list-paths settings]
  (def present (map path/basename list-paths))
  (each name (distinct (map (fn [checkout-row] (checkout-row :from)) (get settings :checkouts [])))
    (unless (index-of name present)
      (error (string settings-file-name ": :checkouts reads " (describe name)
                     ", which is not in the configuration directory")))))

(defn load-repository-lists
  ``Read every repository list and merge them into one list of repositories.
  Errors name the file they came from, since a bad entry is otherwise hard to
  place once several files are in play.``
  [list-paths &opt settings names]
  (default settings default-repository-settings)
  (reject-unknown-sources list-paths settings)
  (merge-repository-lists
    (seq [list-path :in list-paths]
      [list-path
       (try
         (read-repository-list list-path
                               (checkout-rows-for-list settings (path/basename list-path))
                               (get settings :filters {})
                               names)
         ([err] (error (string list-path ": " err))))])))

(defn load-repository-catalog
  ``Discover and load the repository configuration. The returned catalog keeps
  the directory and source paths for command messages, and the repositories
  are resolved and merged in configuration order. `names` narrows source JSON
  before entries are validated, as required by the filter semantics.``
  [directory settings &opt names]
  (default names [])
  (def list-paths (discover-repository-lists directory))
  {:directory directory
   :repository-lists list-paths
   :repositories (load-repository-lists list-paths settings names)})

(defn- configured-jobs
  "Return the configured job count, or the default when it is not set."
  [settings-file]
  (unless (dictionary? settings-file)
    (error "expected a JDN dictionary"))
  (def jobs (get settings-file :jobs parallel/default-jobs))
  (unless (parallel/jobs? jobs)
    (error (string ":jobs must be a positive integer no greater than "
                   parallel/max-jobs)))
  jobs)

(def- custom-command-keys
  "Keys a custom-command definition may contain."
  [:command :command-git :command-jj :description :show-output])

(def- default-command-definitions
  ``Custom commands herd defines itself, written as they would be in :commands
  of config.jdn. A definition of the same name there replaces one.``
  {"diff" {:command-git "git diff HEAD"
           :command-jj "jj diff"
           :description "Show working copy changes in configured repositories beneath a path."
           :show-output "always"}
   "fetch" {:command-git "git fetch"
            :command-jj "jj git fetch"
            :description "Fetch Git remotes in configured repositories beneath a path."}})

(defn- command-from-definition
  "Validate one custom-command definition and return its :command, :description, and :show-output."
  [name definition reserved]
  (unless (and (string? name) (not (empty? name)))
    (error "custom command names must be non-empty strings"))
  (defn fail [message]
    (error (string "custom command \"" name "\" " message)))
  (when (index-of name reserved)
    (fail "conflicts with a built-in command"))
  (unless (dictionary? definition)
    (fail "must be a dictionary"))
  (eachk key definition
    (unless (index-of key custom-command-keys)
      (fail (string "has an unknown key " (describe key)))))
  (def command (get definition :command))
  (def command-git (get definition :command-git))
  (def command-jj (get definition :command-jj))
  (def command-or-vcs-specific
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
  {:command command-or-vcs-specific :description description :show-output show-output})

(defn prepare-settings
  ``Validate the raw settings of config.jdn and return `{:settings :jobs
  :commands}`: the repository settings, the job count, and each custom command
  by name with its `:command`, `:description` and `:show-output`. `reserved`
  names the commands a custom command may not replace. The commands herd
  defines itself are there unless the settings define one of the same name.``
  [settings-file reserved]
  (def jobs (configured-jobs settings-file))
  (def settings (configured-repository-settings settings-file))
  (def definitions (get settings-file :commands {}))
  (unless (dictionary? definitions)
    (error ":commands must be a dictionary"))
  (def commands @{})
  (eachp [name definition] (merge default-command-definitions definitions)
    (put commands name (command-from-definition name definition reserved)))
  {:settings settings :jobs jobs :commands commands})

(defn settings-file-path
  "Return the path of config.jdn, or nil without a configuration directory."
  []
  (when-let [directory (config-directory)]
    (path/join directory settings-file-name)))

(defn load-settings
  ``Read and validate config.jdn in `directory`, as `prepare-settings` does
  with `reserved`. Without the file, or without a directory to look in, the
  settings are the defaults. Errors from the file name it.``
  [directory reserved]
  (def file (when directory (path/join directory settings-file-name)))
  (def stat (when file (os/stat file)))
  (cond
    (nil? stat) (prepare-settings {} reserved)
    (not= :file (stat :mode))
    (error (string file " is not a file"))
    (try
      (prepare-settings (parse-settings-file (slurp file)) reserved)
      ([err] (error (string file ": " err))))))
