# Reading the configuration directory into the repositories it describes.

(import spork/json)
(import spork/path)
(import ./checkout)
(import ./named-filters)
(import ./parallel)
(import ./process)
(import ./run)
(import ./vcs)

(defn- default-config-directory
  ``The configuration directory when HERD_CONFIG names none: the herd
  directory under XDG_CONFIG_HOME or HOME, or nil when neither is set.``
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

(defn- home-anchor?
  "True when `anchor` is ~ or starts with ~/, which means $HOME."
  [anchor]
  (or (= "~" anchor) (string/has-prefix? "~/" anchor)))

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
  # Only a leading ~ or ~/ is expanded. ~user would become a directory of
  # that name.
  (when (and (string? anchor) (string/has-prefix? "~" anchor)
             (not (home-anchor? anchor)))
    (error (string where " has an :anchor " (describe anchor)
                   ": ~USER is not expanded")))
  settings)

(defn- validate-filter-setting
  ``Validate an optional `:use-filters` as an array of filter names. A name
  that starts with "!" keeps what that filter leaves out, as -x does. It is
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
                       "; expected a non-empty string")))
      (when (= "!" name)
        (error (string where " names an invalid filter \"!\""
                       "; expected a filter name after \"!\"")))))
  settings)

(defn- validate-strip-components-setting
  ``Validate an optional :strip-components as a non-negative integer or a
  prefix path ending in "/".``
  [settings where]
  (when (has-key? settings :strip-components)
    (def strip (settings :strip-components))
    (unless (or (and (int? strip) (not (neg? strip)))
                (and (string? strip) (string/has-suffix? "/" strip)))
      (error (string where
                     " needs a non-negative integer or a path ending in"
                     " \"/\" in :strip-components"))))
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
  {:checkout-defaults {} :checkouts [] :filters {} :shell process/default-shell
   :file-name settings-file-name})

(defn- configured-shell
  ``Return the configured shell, the argument vector a command string is
  appended to, or the default.``
  [settings-file]
  (def shell (get settings-file :shell process/default-shell))
  (unless (and (indexed? shell) (not (empty? shell))
               (all (fn [word] (and (string? word) (not (empty? word)))) shell))
    (error `:shell must be a non-empty array of non-empty strings, like ["bash" "-c"]`))
  shell)

(defn configured-repository-settings
  ``Validate repository settings. The checkout rows keep the order they were
  written in. The shell the checkout filters, custom commands and pager run
  in is kept with them, since everything that runs one is handed these.``
  [settings-file]
  (unless (dictionary? settings-file)
    (error "expected a JDN dictionary"))
  (def rows (get settings-file :checkouts []))
  (unless (indexed? rows)
    (error ":checkouts must be an array of rows"))
  (def checkout-rows
    (seq [[index row] :pairs rows]
      (validate-checkout-row row (string ":checkouts row " index))))
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
   :filters filters
   :shell (configured-shell settings-file)})

(defn list-ignored?
  ``Whether the list file `name` is left out because nothing places it: rows
  are written, none reads it, and the defaults set no anchor of their own to
  put it at. Without any rows, every list is placed by the defaults.``
  [settings name]
  (and (not (empty? (get settings :checkouts [])))
       (nil? (get-in settings [:checkout-defaults :anchor]))
       (not (some (fn [checkout-row] (= (checkout-row :list) name))
                  (get settings :checkouts [])))))

(defn checkout-rows-for-list
  ``Merge each checkout row of `name` with the defaults. Return the defaults alone
  when none names the file, or nothing when `list-ignored?`.``
  [settings name]
  (def defaults (get settings :checkout-defaults {}))
  (def matching
    (filter (fn [checkout-row] (= (checkout-row :list) name))
            (get settings :checkouts [])))
  (cond
    (not (empty? matching))
    (map (fn [checkout-row] (merge defaults checkout-row)) matching)
    (list-ignored? settings name) @[]
    @[(merge defaults)]))

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
            (path/abspath (if (home-anchor? anchor)
                            (let [rest (string/triml (string/slice anchor 1) "/")]
                              (if (empty? rest) "." rest))
                            anchor)))
          (error (string "cannot resolve relative anchor for "
                         name " without HOME")))))
    (merge (repository-options checkout-row)
           {:path resolved
            :use-filters (map named-filters/row-step (get checkout-row :use-filters []))
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

(defn- strip-path-prefix
  ``Remove the leading `prefix` from `listed-path`, or return nil when the path
  does not start with it. Both are normalized first, so that `vendor/../x` or
  `vendor//x` cannot leave a remainder that is absolute or climbs out of the
  anchor. Nothing may remain of the path afterwards.``
  [listed-path prefix anchor]
  (def normalized (path/normalize listed-path))
  (def normalized-prefix (path/normalize prefix))
  (when (string/has-prefix? normalized-prefix normalized)
    (def rest (string/slice normalized (length normalized-prefix)))
    (when (empty? (filter (fn [c] (not (empty? c))) (path/parts rest)))
      (error (string "the row anchored at " (describe anchor)
                     " cannot strip prefix " (describe prefix)
                     " from path " (describe listed-path)
                     "; no components remain")))
    rest))

(defn- strip-listed-path
  "Strip by count or by prefix; nil means the entry is ignored."
  [listed-path strip anchor]
  (if (string? strip)
    (strip-path-prefix listed-path strip anchor)
    (strip-path-components listed-path strip anchor)))

(defn resolve-repository-paths
  ``Resolve each entry once per placement, stripping its leading components
  (or its `:strip-components` prefix, ignoring entries that lack it) and
  applying its repository options. Entries without placements produce no
  checkouts.``
  [entries placements]
  (def resolved @[])
  (each placement placements
    (def options (repository-options placement))
    (with-dyns [:path-cwd (placement :path)]
      (each entry entries
        (def listed-path
          (strip-listed-path (entry :path)
                             (get placement :strip-components 0)
                             (placement :path)))
        (when listed-path
          # Apply options from least to most specific: defaults, placement, entry.
          (def settled (merge checkout/default-repository-options options entry))
          (array/push resolved
                      (merge settled
                             {:vcs (vcs/parse (settled :vcs))
                              :path (path/abspath listed-path)
                              # The path as it stands beneath its anchor, for
                              # the commands that run there to be told.
                              :anchored-path listed-path
                              :anchors @[(placement :path)]}))))))
  resolved)

(defn validate-repository-list
  ``Return the repositories that the `entries` of a repository list, decoded
  with string keys, describe, or raise an error describing their shape. Each
  has :path, :clone-url, :vcs when the entry sets it, and :entry, the entry
  with its URL as "clone_url". A list may spell the URL "clone_url" or, as
  older lists do, "ssh_url", or carry both, as checkout/url-key chooses.
  Only these fields become repository settings, so no other field of a list
  can set one.``
  [entries]
  (unless (indexed? entries)
    (error "expected a JSON array of repository objects"))
  (seq [[index entry] :pairs entries]
    (unless (dictionary? entry)
      (error (string "entry " index " is not a JSON object")))
    (def listed-path (entry "path"))
    (unless (string? listed-path)
      (error (string "entry " index " needs a string \"path\"")))
    # An empty path would make the anchor itself a repository.
    (when (empty? listed-path)
      (error (string "entry " index " needs a non-empty \"path\"")))
    # Every repository lies beneath the anchor of its placement, which is how
    # a placement that cannot be read is known to affect only that subtree.
    (when (path/abspath? listed-path)
      (error (string "entry " index " has an absolute \"path\"; write it"
                     " relative to its anchor")))
    (when (index-of ".." (path/parts listed-path))
      (error (string "entry " index " has a \"path\" with a \"..\" component")))
    (def url-key (checkout/url-key entry))
    (def url (entry url-key))
    (unless (string? url)
      (error (string "entry " index " needs a string \"" url-key "\"")))
    (when (empty? url)
      (error (string "entry " index " needs a non-empty \"" url-key "\"")))
    (def spelled @{})
    (eachp [key value] entry
      (unless (index-of key checkout/url-keys)
        (put spelled key value)))
    (put spelled "clone_url" url)
    (def repository @{:path listed-path :clone-url url :entry spelled})
    (when (has-key? entry "vcs")
      (put repository :vcs (entry "vcs")))
    (checkout/validate-repository-options repository (string "entry " index) `"vcs"`)))

(defn- json-from-jdn
  ``Return the JDN `value` as decoded JSON holds it: tables with string keys,
  arrays, strings for keywords, symbols and buffers, and :null for nil and
  for :null, as a JSON null.``
  [value]
  (cond
    (dictionary? value)
    (tabseq [[key field] :pairs value] (string key) (json-from-jdn field))

    (indexed? value) (map json-from-jdn value)
    (or (nil? value) (= :null value)) :null
    (or (keyword? value) (symbol? value) (buffer? value)) (string value)
    value))

(defn- inline-list-entries
  ``Return the inline repository list `entries` as the decoded JSON of a file,
  so that filters and validation see it as they see a file. A key written
  `:clone-url` becomes `clone_url`, the way the files spell it.``
  [entries]
  (unless (indexed? entries)
    (error "expected an array of repositories"))
  (seq [[index entry] :pairs entries]
    (unless (dictionary? entry)
      (error (string "entry " index " is not a dictionary")))
    (when (has-key? entry :ssh_url)
      (error (string "entry " index " needs :clone-url, not :ssh_url")))
    (tabseq [[key value] :pairs entry]
      (if (keyword? key) (string/replace-all "-" "_" key) (string key))
      (json-from-jdn value))))

(defn- read-list-entries
  ``Read one repository list. Return one record for each placement of the
  list, in the order of `checkout-rows`:

    {:placement placement   # the anchor, options, filters and strip of the row
     :label list-label      # the list as a listing names it
     :source source         # the list as an error names it
     :repositories @[...]   # the checkouts, empty for a broken placement
     :broken nil}           # or `{:kind :message}`

  `load-entries` returns the list as decoded JSON. It is called only when a
  placement needs the entries, so a list that no row places, or whose
  placements cannot run their filters, is never loaded. A row filters before
  its anchor is applied, so each row can describe a different part of the
  same list, and the steps in `names` narrow every row further. Only the
  entries a filter kept are validated: a list may carry entries herd could
  not use, which is the point of filtering it.

  A placement whose filters cannot run, because the program is missing, is
  broken with the kind :no-filter-program. It does not fail the read, so
  that only a command that needs the placement has to fail.``
  [load-entries source list-label checkout-rows filters names]
  # Rows sharing a chain are the common case, so filter once for each distinct
  # chain rather than once for every anchor. The chain itself is the key: a
  # filter name is an arbitrary string, so joining names into one would let
  # two different chains spell the same key and hand a row the repositories
  # another row had selected.
  (def selected @{})
  (seq [placement :in (resolve-checkout-rows source checkout-rows)]
    (def chain [;(placement :use-filters) ;names])
    (def broken
      (when (and (not (empty? chain)) (not (named-filters/executable-available?)))
        {:kind :no-filter-program
         :message (string source ": " (named-filters/missing-executable-message ((first chain) :name)))}))
    (def kept
      (cond
        broken nil
        (has-key? selected chain) (get selected chain)
        # A row aimed its own filters at this file; the command line aimed
        # its filters at every file, so only those need to explain themselves.
        (let [computed (validate-repository-list
                         (named-filters/narrow filters (load-entries) (placement :use-filters) names))]
          (put selected chain computed)
          computed)))
    {:placement placement
     :label list-label
     :source source
     :repositories (if kept (resolve-repository-paths kept [placement]) @[])
     :broken broken}))

(defn read-list-placements
  ``Read the repository list in the file `list-path`. Return one record for
  each placement that `checkout-rows` give the list, as `{:placement :label
  :source :repositories :broken}`. `filters` is the registry of filters, and
  the steps in `names` narrow every row. The file is decoded once, and only
  when a placement needs its entries, so a file that does not parse fails
  only a read that needs it.``
  [list-path checkout-rows &opt filters names]
  # When the decode fails, a second call of the delay returns nil. That
  # cannot occur, because the error ends the read.
  (read-list-entries (delay (json/decode (slurp list-path)))
                     list-path
                     (path/basename list-path)
                     checkout-rows
                     (or filters {})
                     (or names [])))

(defn read-inline-placements
  ``Read the repository list held inline by a `:checkouts` row, which is
  `list-label` to errors. Return the record of its placement in an array, as
  `{:placement :label :source :repositories :broken}`. The row must already
  have its defaults merged.``
  [list-label checkout-row &opt filters names]
  (def entries (inline-list-entries (checkout-row :list)))
  (read-list-entries |entries list-label list-label [checkout-row]
                     (or filters {}) (or names [])))

(defn- placed-repositories
  ``The repositories of the placement records `placements`, in order. Raise
  with the message of the first broken placement.``
  [placements]
  (when-let [broken (some (fn [placement] (placement :broken)) placements)]
    (error (broken :message)))
  (array/concat @[] ;(map (fn [placement] (placement :repositories)) placements)))

(defn read-repository-list
  ``Read the repository list in the file `list-path` and return the checkouts
  that `checkout-rows` place. Raise when a placement is broken. `filters` is
  the registry of filters, and the steps in `names` narrow every row.``
  [list-path checkout-rows &opt filters names]
  (placed-repositories (read-list-placements list-path checkout-rows filters names)))

(defn read-inline-list
  ``Read the repository list held inline by a `:checkouts` row, which is
  `list-label` to errors, and return its checkouts. Raise when the placement
  is broken. The row must already have its defaults merged.``
  [list-label checkout-row &opt filters names]
  (placed-repositories (read-inline-placements list-label checkout-row filters names)))

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

(defn- missing-list-placements
  ``One placement record for each `:checkouts` row of `settings` that reads a
  list file which is not among `list-paths`. Each record is broken with the
  kind :no-list-file and has no repositories. The record prevents a renamed
  list from silently using the defaults, and only a command that has to read
  the placement fails.``
  [list-paths settings]
  (def present (map path/basename list-paths))
  (def defaults (get settings :checkout-defaults {}))
  (def placements @[])
  (each row (get settings :checkouts [])
    (def name (row :list))
    (when (and (string? name) (not (index-of name present)))
      (def message (string (get settings :file-name settings-file-name)
                           ": :checkouts reads " (describe name)
                           ", which is not in the configuration directory"))
      (each placement (resolve-checkout-rows name [(merge defaults row)])
        (array/push placements {:placement placement
                                :label name
                                :source name
                                :repositories @[]
                                :broken {:kind :no-list-file :message message}}))))
  placements)

(defn inline-lists
  ``Return `[list-label row]` for each `:checkouts` row of `settings` that holds
  its list inline, with the defaults merged into the row.``
  [settings]
  (def defaults (get settings :checkout-defaults {}))
  (seq [[index row] :pairs (get settings :checkouts [])
        :when (indexed? (row :list))]
    [(string (get settings :file-name settings-file-name) ": "
             (inline-list-label index))
     (merge defaults row)]))

(defn load-placements
  ``Read every repository list and return one record for each placement, as
  `{:placement :label :source :repositories :broken}`. The rows whose list
  file is missing come first, then the files in `list-paths`, then the lists
  held inline by `:checkouts` rows. The steps in `names` narrow every list.
  A broken placement has a `:broken` with `:kind` and `:message`, and no
  repositories. Errors name the list they came from, since a bad entry is
  otherwise hard to place once several are in play.``
  [list-paths &opt settings names]
  (default settings default-repository-settings)
  (def filters (get settings :filters {}))
  (def placements (missing-list-placements list-paths settings))
  (each list-path list-paths
    (array/concat
      placements
      (try
        (read-list-placements list-path
                              (checkout-rows-for-list settings (path/basename list-path))
                              filters
                              names)
        ([err] (error (string list-path ": " err))))))
  (each [list-label row] (inline-lists settings)
    (array/concat
      placements
      (try
        (read-inline-placements list-label row filters names)
        ([err] (error (string list-label ": " err))))))
  placements)

(defn- merge-placements
  "Merge the repositories of the placement records `placements` into one list."
  [placements]
  (merge-repository-lists
    (map (fn [placement] [(placement :source) (placement :repositories)])
         placements)))

(defn load-repository-lists
  ``Read every repository list, as `load-placements` does, and merge the
  placements into one list of repositories. Raise when a placement is
  broken.``
  [list-paths &opt settings names]
  (def placements (load-placements list-paths settings names))
  (when-let [broken (some (fn [placement] (placement :broken)) placements)]
    (error (broken :message)))
  (merge-placements placements))

(defn load-repository-catalog
  ``Discover and load the repository configuration. The returned catalog keeps
  the directory and source paths for command messages. `:placements` holds
  the records that `load-placements` returns, and `:repositories` is their
  merge, in configuration order. The steps in `names` narrow the decoded
  lists before entries are validated, as required by the filter semantics.``
  [directory settings &opt names]
  (default names [])
  (def list-paths (discover-repository-lists directory))
  (def placements (load-placements list-paths settings names))
  {:directory directory
   :repository-lists list-paths
   :inline-lists (map first (inline-lists settings))
   :placements placements
   :repositories (merge-placements placements)
   # The placements that could not be read, `{:anchor :message}`.
   :broken (seq [placement :in placements
                 :let [broken (placement :broken)]
                 :when broken]
             {:anchor ((placement :placement) :path) :message (broken :message)})})

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
  ``The command trees, and the results of commands that ask for it, are shown
  through on a terminal, unless :pager says otherwise.``
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
  [:command :command-git :command-jj :description :show-output :pager])

(def- default-command-definitions
  ``Custom commands herd defines itself, written as they would be in :commands
  of config.jdn. A definition of the same name there replaces one.``
  {"diff" {:command-git `git diff --color="$HERD_COLOR" HEAD "$@"`
           :command-jj `jj diff --color="$HERD_COLOR" "$@"`
           :description "Show working copy changes in configured repositories beneath a path."
           :show-output "always"
           :pager true}
   "fetch" {:command-git `git fetch "$@"`
            :command-jj `jj git fetch --color="$HERD_COLOR" "$@"`
            :description "Fetch Git remotes in configured repositories beneath a path."}})

(defn- command-from-definition
  ``Validate one custom-command definition and return its :command,
  :description, :show-output, and :pager, whether its results are shown
  through the pager, false unless it says.``
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
        (unless (and (string? command) (not (empty? command)))
          (fail "needs a non-empty string :command"))
        (when (or (not (nil? command-git)) (not (nil? command-jj)))
          (fail "cannot combine :command with VCS-specific commands"))
        command)
      (do
        (when (and (nil? command-git) (nil? command-jj))
          (fail "needs :command, :command-git, or :command-jj"))
        (unless (or (nil? command-git)
                    (and (string? command-git) (not (empty? command-git))))
          (fail "needs a non-empty string :command-git"))
        (unless (or (nil? command-jj)
                    (and (string? command-jj) (not (empty? command-jj))))
          (fail "needs a non-empty string :command-jj"))
        {:command-git command-git :command-jj command-jj})))
  (def description (get definition :description))
  (unless (string? description)
    (fail "needs a string :description"))
  (def show-output (get definition :show-output run/default-show-output))
  (try
    (run/require-show-output show-output)
    ([err]
      (fail (string "has an invalid :show-output; " err))))
  (def pager (get definition :pager false))
  (unless (boolean? pager)
    (fail "needs true or false for :pager"))
  {:command command-or-vcs-specific :description description :show-output show-output
   :pager pager})

(def- settings-keys
  "Keys the settings file may hold at its top level."
  [:jobs :pager :shell :checkout-defaults :checkouts :filters :commands])

(defn prepare-settings
  ``Validate the raw settings of config.jdn and return `{:settings :jobs
  :pager :commands}`: the repository settings, the job count, the pager
  command (false for none), and each custom command
  by name with its `:command`, `:description`, `:show-output` and `:pager`. `reserved`
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

(defn- named-location
  ``The `{:directory :settings-file}` of the configuration `named`, a
  directory read as the configuration directory or a settings file read in
  place of config.jdn with the lists beside it. A name that is neither is an
  error naming `source`, where it came from: unlike the default directory, a
  configuration asked for by name is not merely absent.``
  [named source]
  (def target (path/abspath named))
  (case (os/stat target :mode)
    :directory {:directory target
                :settings-file (path/join target settings-file-name)}
    :file {:directory (parent-path target) :settings-file target}
    nil (error (string source " names " target ", which does not exist"))
    (error (string source " names " target
                   ", which is neither a file nor a directory"))))

(defn config-location
  ``Return `{:directory :settings-file}`: the directory holding the JSON
  repository lists, and the settings file. HERD_CONFIG, when set, names
  them as `named-location` reads a name. Otherwise the directory is the
  default one, and nil is returned without one.``
  []
  (def named (os/getenv "HERD_CONFIG"))
  (if (and named (not (empty? named)))
    (named-location named "HERD_CONFIG")
    (when-let [directory (default-config-directory)]
      {:directory directory
       :settings-file (path/join directory settings-file-name)})))

(defn use-config
  ``Read the configuration `named` from now on, in place of HERD_CONFIG, as
  --config asks. A name that names nothing is an error naming --config.
  HERD_CONFIG is set to the absolute path, so that a herd started by a
  command, in a repository of its own, reads the same configuration.``
  [named]
  (when (empty? named)
    (error "--config names no configuration"))
  (named-location named "--config")
  (os/setenv "HERD_CONFIG" (path/abspath named)))

(defn pin-config
  ``Set HERD_CONFIG to the absolute path of the configuration in use: the one
  it names, or the default directory when it names none and that exists. A
  command then finds the configuration herd reads, and a herd started by one,
  in a repository of its own, reads it too. Without a configuration it is
  left alone.``
  []
  (def named (os/getenv "HERD_CONFIG"))
  (if (and named (not (empty? named)))
    (do
      (named-location named "HERD_CONFIG")
      (os/setenv "HERD_CONFIG" (path/abspath named)))
    (when-let [directory (default-config-directory)]
      (when (= :directory (os/stat directory :mode))
        (os/setenv "HERD_CONFIG" (path/abspath directory))))))

(defn config-directory
  ``Directory holding the JSON repository lists, as `config-location` finds
  it, or nil without one.``
  []
  (get (config-location) :directory))

(defn settings-file-path
  ``Return the path of the settings file, as `config-location` finds it, or
  nil without a configuration directory.``
  []
  (get (config-location) :settings-file))

(defn load-settings
  ``Read and validate the settings `file`, as `prepare-settings` does with
  `reserved`. Without the file, or without a file to look for, the settings
  are the defaults. Errors from the file name it, and the repository
  settings keep its name as `:file-name` for the messages that cite it.``
  [file reserved]
  (def stat (when file (os/stat file)))
  (cond
    (nil? stat) (prepare-settings {} reserved)
    (not= :file (stat :mode))
    (error (string file " is not a file"))
    (let [loaded (try
                   (prepare-settings (parse-settings-file (slurp file)) reserved)
                   ([err] (error (string file ": " err))))]
      (merge loaded
             {:settings (merge (loaded :settings)
                               {:file-name (path/basename file)})}))))
