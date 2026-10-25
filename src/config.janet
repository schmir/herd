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
  [:list :anchor :use-filters :strip-components])

(defn- reject-unknown-setting
  "Raise for a setting that is not configurable."
  [where key known]
  (unless (index-of key known)
    (error (string where " has an unknown setting " (describe key)))))

(defn- validate-anchor-setting
  ``Validate an optional anchor as a non-empty string. `:checkout-defaults` may also
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
  ``Validate an optional `:use-filters` as an array of filter names. It is
  always an array, even for a single name, so there is one shape to write and
  one to read. An empty array filters nothing, which is how a row drops the
  filters it would otherwise inherit from `:checkout-defaults`.``
  [settings where]
  (def names (get settings :use-filters :unset))
  (unless (= :unset names)
    (unless (indexed? names)
      (error (string where " needs an array of filter names in :use-filters")))
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
  repository list or hold one inline.``
  [checkout-row where]
  (unless (dictionary? checkout-row)
    (error (string where " must be a dictionary")))
  (eachk key checkout-row
    (reject-unknown-setting where key [;checkout-row-keys ;checkout/option-keys]))
  (def list-name (get checkout-row :list))
  (unless (or (and (string? list-name) (not (empty? list-name)))
              (indexed? list-name))
    (error (string where " needs a :list naming a repository list"
                   " or holding an array of repositories")))
  (validate-anchor-setting checkout-row where)
  (validate-filter-setting checkout-row where)
  (validate-strip-components-setting checkout-row where)
  (checkout/validate-repository-options checkout-row where)
  checkout-row)

(defn validate-checkout-defaults
  "Validate `:checkout-defaults` and return them. Defaults cannot name a source."
  [defaults]
  (unless (dictionary? defaults)
    (error ":checkout-defaults must be a dictionary"))
  (eachk key defaults
    (reject-unknown-setting ":checkout-defaults" key [:anchor :use-filters ;checkout/option-keys]))
  (validate-anchor-setting defaults ":checkout-defaults" true)
  (validate-filter-setting defaults ":checkout-defaults")
  (checkout/validate-repository-options defaults ":checkout-defaults")
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

(defn- inline-list-label
  "Name the inline list of `:checkouts` row `index`, as errors must."
  [index]
  (string ":checkouts row " index))

(def default-repository-settings
  "Repository settings used when the settings file is absent."
  {:checkout-defaults {} :checkouts [] :filters {}})

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
  (def defaults (validate-checkout-defaults (get settings-file :checkout-defaults {})))
  (named-filters/require-list-filters filters (get defaults :use-filters []) ":checkout-defaults")
  (eachp [index checkout-row] checkout-rows
    (named-filters/require-list-filters filters (get checkout-row :use-filters [])
                                        (if (string? (checkout-row :list))
                                          (string ":checkouts row for "
                                                  (describe (checkout-row :list)))
                                          (inline-list-label index))))
  {:checkout-defaults defaults
   :checkouts checkout-rows
   :filters filters})

(defn checkout-rows-for-list
  ``Merge each checkout row of `name` with the defaults. Return the defaults alone
  when none names the file.``
  [settings name]
  (def defaults (get settings :checkout-defaults {}))
  (def matching
    (filter (fn [checkout-row] (= (checkout-row :list) name))
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
            :use-filters (get checkout-row :use-filters [])
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

(def- url-keys
  "The names a repository list may give the URL a repository is cloned from."
  [:clone_url :ssh_url])

(defn validate-repository-list
  ``Return the `entries` of a repository list with the clone URL of each under
  `:clone-url`, or raise an error describing their shape. A list may spell the
  URL `clone_url` or, as older lists do, `ssh_url`, but not both.``
  [entries]
  (unless (indexed? entries)
    (error "expected a JSON array of repository objects"))
  (seq [index :range [0 (length entries)]]
    (def entry (entries index))
    (unless (dictionary? entry)
      (error (string "entry " index " is not a JSON object")))
    (unless (string? (entry :path))
      (error (string "entry " index " needs a string \"path\"")))
    (when (and (not (path/abspath? (entry :path)))
               (index-of ".." (path/parts (path/normalize (entry :path)))))
      (error (string "entry " index " has a relative \"path\" that leaves"
                     " its anchor; write an absolute path instead")))
    (def spelled (filter (fn [key] (not (nil? (entry key)))) url-keys))
    (when (= 2 (length spelled))
      (error (string "entry " index " has both \"clone_url\" and \"ssh_url\"")))
    (def url-key (get spelled 0 :clone_url))
    (unless (string? (entry url-key))
      (error (string "entry " index " needs a string \"" url-key "\"")))
    (checkout/validate-repository-options entry (string "entry " index) `"vcs"`)
    (def normalized @{})
    (eachp [key value] entry
      (unless (index-of key url-keys)
        (put normalized key value)))
    (put normalized :clone-url (entry url-key))))

(defn- inline-list-source
  ``Return the JSON that stands for the inline repository list `entries`, so
  that filters and validation see it as they see a file. A key written
  `:clone-url` becomes `clone_url`, the way the files spell it.``
  [entries]
  (unless (indexed? entries)
    (error "expected an array of repositories"))
  (json/encode
    (seq [index :range [0 (length entries)]]
      (def entry (entries index))
      (unless (dictionary? entry)
        (error (string "entry " index " is not a dictionary")))
      (when (has-key? entry :ssh_url)
        (error (string "entry " index " needs :clone-url, not :ssh_url")))
      (def spelled @{})
      (eachp [key value] entry
        (put spelled (if (keyword? key) (string/replace-all "-" "_" key) key) value))
      spelled)))

(defn- read-list-source
  ``Read the JSON `source` of one repository list, resolving each repository
  into checkouts. `label` names the list, as a file path does a file. A row
  filters before its anchor is applied, so each row can describe a different
  part of the same list, and `names` narrows every row further. Only the
  entries a filter kept are validated: a list may carry entries herd could
  not use, which is the point of filtering it. The source is decoded once,
  after the filters have had it, so what they see is the list itself.``
  [source label checkout-rows filters names]
  (def placements (resolve-checkout-rows label checkout-rows))
  (def resolved @[])
  # Rows sharing a chain are the common case, so filter once for each distinct
  # chain rather than once for every anchor. The chain itself is the key: a
  # filter name is an arbitrary string, so joining names into one would let
  # two different chains spell the same key and hand a row the repositories
  # another row had selected.
  (def selected @{})
  (each placement placements
    (def chain [;(placement :use-filters) ;names])
    (def kept
      (if (has-key? selected chain)
        (get selected chain)
        # A row aimed its own filters at this file; the command line aimed
        # its filters at every file, so only those need to explain themselves.
        (let [computed (validate-repository-list
                         (json/decode
                           (named-filters/narrow filters source (placement :use-filters) names)
                           true))]
          (put selected chain computed)
          computed)))
    (array/concat resolved (resolve-repository-paths kept [placement])))
  resolved)

(defn read-repository-list
  ``Read the repository list in the file `list-path`, resolving each
  repository into checkouts as `read-list-source` does.``
  [list-path checkout-rows &opt filters names]
  (read-list-source (slurp list-path) list-path checkout-rows
                    (or filters {}) (or names [])))

(defn read-inline-list
  ``Read the repository list held inline by a `:checkouts` row, which is
  `label` to errors, resolving each repository into checkouts as
  `read-list-source` does. The row must already have its defaults merged.``
  [label checkout-row &opt filters names]
  (read-list-source (inline-list-source (checkout-row :list)) label
                    [checkout-row] (or filters {}) (or names [])))

(defn- parent-path
  "The directory holding `repository-path`, without a trailing slash."
  [repository-path]
  (def slash (last (string/find-all path/sep repository-path)))
  (when (and slash (pos? slash))
    (string/slice repository-path 0 slash)))

(defn reject-nested-repositories
  ``Reject a repository whose path lies inside another repository's. `seen`
  maps each path to the `:source` that named it.``
  [seen]
  (eachk repository-path seen
    (var ancestor (parent-path repository-path))
    (while ancestor
      (when-let [outer (get seen ancestor)]
        (error (string/format "%s names %s, which lies inside the repository %s from %s"
                              ((get seen repository-path) :source) repository-path
                              ancestor (outer :source))))
      (set ancestor (parent-path ancestor)))))

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
                :clone-url (repository :clone-url)
                :options (repository-options repository)
                :anchors (repository :anchors)})
          (array/push merged repository))

        (not= (previous :clone-url) (repository :clone-url))
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
  (reject-nested-repositories seen)
  merged)

(defn- reject-unknown-sources
  ``Reject checkouts whose source file is missing. This prevents a
  renamed list from silently using the defaults.``
  [list-paths settings]
  (def present (map path/basename list-paths))
  (each name (distinct (filter string? (map (fn [checkout-row] (checkout-row :list)) (get settings :checkouts []))))
    (unless (index-of name present)
      (error (string settings-file-name ": :checkouts reads " (describe name)
                     ", which is not in the configuration directory")))))

(defn inline-lists
  ``Return `[label row]` for each `:checkouts` row of `settings` that holds
  its list inline, with the defaults merged into the row.``
  [settings]
  (def defaults (get settings :checkout-defaults {}))
  (seq [[index row] :pairs (get settings :checkouts [])
        :when (indexed? (row :list))]
    [(string settings-file-name ": " (inline-list-label index))
     (merge defaults row)]))

(defn load-repository-lists
  ``Read every repository list and merge them into one list of repositories.
  The files come first, then the lists held inline by `:checkouts` rows.
  Errors name the list they came from, since a bad entry is otherwise hard to
  place once several are in play.``
  [list-paths &opt settings names]
  (default settings default-repository-settings)
  (reject-unknown-sources list-paths settings)
  (def filters (get settings :filters {}))
  (merge-repository-lists
    [;(seq [list-path :in list-paths]
        [list-path
         (try
           (read-repository-list list-path
                                 (checkout-rows-for-list settings (path/basename list-path))
                                 filters
                                 names)
           ([err] (error (string list-path ": " err))))])
     ;(seq [[label row] :in (inline-lists settings)]
        [label
         (try
           (read-inline-list label row filters names)
           ([err] (error (string label ": " err))))])]))

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
   :inline-lists (map first (inline-lists settings))
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

(def default-pager
  "The command trees are shown through on a terminal, unless :pager says otherwise."
  "less -FXR")

(defn- configured-pager
  "Return the configured pager command, false for none, or the default."
  [settings-file]
  (def pager (get settings-file :pager default-pager))
  (unless (or (false? pager) (and (string? pager) (not (empty? pager))))
    (error ":pager must be a non-empty command string, or false for no pager"))
  pager)

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

(def- settings-keys
  "Keys the settings file may hold at its top level."
  [:jobs :pager :checkout-defaults :checkouts :filters :commands])

(defn prepare-settings
  ``Validate the raw settings of config.jdn and return `{:settings :jobs
  :pager :commands}`: the repository settings, the job count, the pager
  command (false for none), and each custom command
  by name with its `:command`, `:description` and `:show-output`. `reserved`
  names the commands a custom command may not replace. The commands herd
  defines itself are there unless the settings define one of the same name.``
  [settings-file reserved]
  (def jobs (configured-jobs settings-file))
  (def pager (configured-pager settings-file))
  (eachk key settings-file
    (reject-unknown-setting "the top level" key settings-keys))
  (def settings (configured-repository-settings settings-file))
  (def definitions (get settings-file :commands {}))
  (unless (dictionary? definitions)
    (error ":commands must be a dictionary"))
  (def commands @{})
  (eachp [name definition] (merge default-command-definitions definitions)
    (put commands name (command-from-definition name definition reserved)))
  {:settings settings :jobs jobs :pager pager :commands commands})

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
