# Reading the configuration directory into the repositories it describes.

(import spork/path)
(import ./filter)
(import ./checkout)
(import ./entries)

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
  [:from :anchor :filter :strip-components])

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
  configuration file.``
  [row where]
  (unless (dictionary? row)
    (error (string where " must be a dictionary")))
  (eachk key row
    (reject-unknown-setting where key [;checkout-row-keys ;checkout/checkout-keys]))
  (def from (get row :from))
  (unless (and (string? from) (not (empty? from)))
    (error (string where " needs a :from naming a configuration file")))
  (validate-anchor-setting row where)
  (validate-filter-setting row where)
  (validate-strip-components-setting row where)
  (checkout/validate-checkout-options row where)
  row)

(defn validate-checkout-defaults
  "Validate `:defaults` and return them. Defaults cannot name a source."
  [defaults]
  (unless (dictionary? defaults)
    (error ":defaults must be a dictionary"))
  (eachk key defaults
    (reject-unknown-setting ":defaults" key [:anchor :filter ;checkout/checkout-keys]))
  (validate-anchor-setting defaults ":defaults")
  (validate-filter-setting defaults ":defaults")
  (checkout/validate-checkout-options defaults ":defaults")
  defaults)

(defn validate-filters
  ``Validate the `:filters` registry and return it. It maps a filter name to
  the JMESPath expression it stands for; every reference elsewhere names one
  of these, so a mistyped name is caught rather than silently selecting
  nothing.``
  [filters]
  (unless (dictionary? filters)
    (error ":filters must be a dictionary of names to expressions"))
  (eachp [name expression] filters
    (unless (and (string? name) (not (empty? name)))
      (error "filter names must be non-empty strings"))
    (unless (and (string? expression) (not (empty? expression)))
      (error (string "filter " (describe name)
                     " needs a non-empty expression"))))
  filters)

(defn- reject-unknown-filters
  "Raise for a `:filter` that names a filter the registry does not define."
  [settings where filters]
  (each name (get settings :filter [])
    (unless (get filters name)
      (error (string where " names an unknown filter " (describe name)))))
  settings)

(def default-repository-settings
  "Repository settings used when config.jdn is absent."
  {:defaults {} :rows {} :filters {}})

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
  (def filters (validate-filters (get config :filters {})))
  (def defaults (validate-checkout-defaults (get config :defaults {})))
  (reject-unknown-filters defaults ":defaults" filters)
  (eachp [from written] rows
    (for index 0 (length written)
      (reject-unknown-filters (written index)
                              (string ":checkouts row for " (describe from))
                              filters)))
  {:defaults defaults
   :rows rows
   :filters filters})

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
  (each key checkout/checkout-keys
    (def value (get source key))
    (unless (nil? value)
      (put options key value)))
  options)

(defn config-anchors
  ``Resolve one anchor for each checkout row and retain its options and its
  filter and path settings. Relative anchors use HOME. A missing anchor uses
  HOME for configured files and the file's parent otherwise. Keep configured
  paths because selection resolves symbolic links.``
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
    (merge (checkout-options row)
           {:path resolved
            :filter (get row :filter [])
            :strip-components (get row :strip-components 0)})))

(defn- strip-path-components
  ``Remove `strip-count` leading components and return a relative path. The
  `anchor` only names the row in the error, since a file read under several
  anchors strips a different number of components under each.``
  [repository-path strip-count anchor]
  (if (zero? strip-count)
    repository-path
    (let [components (filter |(not (empty? $))
                             (path/parts (path/normalize repository-path)))]
      (when (>= strip-count (length components))
        (error (string "the row anchored at " (describe anchor)
                       " cannot strip " strip-count " components from path "
                       (describe repository-path) "; no components remain")))
      (string/join (drop strip-count components) path/sep))))

(defn resolve-repository-paths
  ``Resolve each entry once per anchor, stripping its leading components and
  applying its checkout options. Entries without anchors produce no
  checkouts. Unstripped absolute paths remain the same under all anchors so
  `merge-configs` can combine them.``
  [entries anchors]
  (def resolved @[])
  (each anchor anchors
    (def options (checkout-options anchor))
    (with-dyns [:path-cwd (anchor :path)]
      (each entry entries
        (def repository-path
          (strip-path-components (entry :path)
                                 (get anchor :strip-components 0)
                                 (anchor :path)))
        # Apply options from least to most specific: defaults, anchor, entry.
        (array/push resolved
                    (merge checkout/default-checkout-options options entry
                           {:path (path/abspath repository-path)
                            :anchors @[(anchor :path)]})))))
  resolved)

(defn read-config
  ``Read one configuration file, resolving each repository into checkouts.
  A row filters before its anchor is applied, so each row can describe a
  different part of the same list, and `names` narrows every row further.
  Only the entries a filter kept are validated: a list may carry entries herd
  could not use, which is the point of filtering it. The file is decoded once,
  after the filters have had it, so what they see is the file itself.``
  [config-path directory rows &opt filters names]
  (default filters {})
  (default names [])
  (def source (slurp config-path))
  (def anchors (config-anchors config-path directory rows))
  (def resolved @[])
  # Rows sharing a chain are the common case, so filter once for each distinct
  # chain rather than once for every anchor. The chain itself is the key: a
  # filter name is an arbitrary string, so joining names into one would let
  # two different chains spell the same key and hand a row the repositories
  # another row had selected.
  (def selected @{})
  (each anchor anchors
    (def chain [;(anchor :filter) ;names])
    (def kept
      (if (has-key? selected chain)
        (get selected chain)
        # A row aimed its own filters at this file; the command line aimed
        # its filters at every file, so only those need to explain themselves.
        (let [computed (entries/validate-config
                         (entries/parse-config
                           (filter/filter-entries
                             (filter/filter-entries source (anchor :filter) filters)
                             names filters filter/command-filter-hint)))]
          (put selected chain computed)
          computed)))
    (array/concat resolved (resolve-repository-paths kept [anchor])))
  resolved)

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
  [config-paths directory &opt settings names]
  (default settings default-repository-settings)
  (reject-unknown-sources settings config-paths)
  (merge-configs
    (seq [config-path :in config-paths]
      [config-path
       (try
         (read-config config-path directory
                      (rows-for-file settings (path/basename config-path))
                      (get settings :filters {})
                      names)
         ([err] (error (string config-path ": " err))))])))
