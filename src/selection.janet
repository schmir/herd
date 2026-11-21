# Choosing the repositories a command acts on, and saying why there are none.

(import ./config)
(import ./named-filters)
(import ./location)
(import ./process)
(import ./sample)
(import ./stages)

(defn- bare-word?
  "Whether `value` is a single word, which names a program rather than a script."
  [value]
  (not (or (string/find " " value) (string/find "\t" value)
           (string/find "/" value))))

(defn- mistyped?
  ``Whether `value`, given with -f, is neither a filter nor a command. A single
  word that no program on PATH answers to was most likely a filter name with
  a typo in it.``
  [value]
  (and (bare-word? value) (not (process/find-executable value))))

(defn resolve-filters
  ``Give each of the filter steps `steps`, from -f and -x, its `:kind`, and
  return them in the order given. The name of a list filter in `settings`
  makes a :list step, which narrows the lists. The name of a checkout filter
  makes a :checkout step with the `:command` of the filter. Any other name is
  a shell command itself, and makes a :checkout step with the name as its
  `:command`. A name that is neither a filter nor a command makes a :mistyped
  step.``
  [steps settings]
  (def registry (get settings :filters {}))
  (seq [step :in steps]
    (def name (step :name))
    (def command (named-filters/checkout-filter-command registry name))
    (cond
      (named-filters/list-filter? registry name) (struct ;(kvs step) :kind :list)
      (and (nil? command) (mistyped? name)) (struct ;(kvs step) :kind :mistyped)
      (struct ;(kvs step) :kind :checkout :command (or command name)))))

(defn- steps-of-kind
  "The resolved filter steps in `steps` that have the kind `kind`, in order."
  [steps kind]
  (filter (fn [step] (= kind (step :kind))) steps))

(defn list-steps
  "The resolved filter steps in `steps` that narrow the lists, in order."
  [steps]
  (steps-of-kind steps :list))

(defn checkout-steps
  "The resolved filter steps in `steps` that run in the checkouts, in order."
  [steps]
  (steps-of-kind steps :checkout))

(defn- filters-in-play?
  ``Whether any filter narrows this run, named on the command line or by a
  checkout row. An empty result is worth explaining only when something could
  have removed the repositories.``
  [names settings]
  (or (not (empty? names))
      (not (empty? (get-in settings [:checkout-defaults :use-filters] [])))
      (true? (some (fn [checkout-row] (not (empty? (get checkout-row :use-filters []))))
                   (get settings :checkouts [])))))

(defn- why-empty
  "The reason a selection from `repositories` picked nothing."
  [options list-filters settings repositories anchors]
  (cond
    (and (empty? repositories) (filters-in-play? list-filters settings))
    {:kind :emptied-by-filters :list-filters list-filters
     :file-name (get settings :file-name config/settings-file-name)}

    (empty? repositories) {:kind :empty-catalog}

    (empty? anchors)
    {:kind :no-anchor-contains-path :at-path (options :at-path)}

    {:kind :none-beneath-path :at-path (options :at-path)}))

(defn- narrow-by-stages
  ``Keep the `repositories` in the `:requested-state` that `options` asks for,
  and that pass the checkout filter steps `steps`. An interrupt during a stage
  ends the selection there, since what it kept is only some of what it would
  have. The commands run in `shell`. Return `{:repositories :interrupted?}`.``
  [options repositories steps shell]
  (var kept repositories)
  (var interrupted? false)
  (try
    (do
      (when (options :requested-state)
        (def stage (stages/filter-by-state kept (options :requested-state)
                                           (options :jobs)))
        (set kept (stage :repositories))
        (set interrupted? (stage :interrupted?)))
      (when (and (not interrupted?) (not (empty? steps)))
        (def stage (stages/filter-by-commands kept steps (options :jobs) shell
                                              (options :at-path)))
        (set kept (stage :repositories))
        (set interrupted? (stage :interrupted?))))
    ([err] (error {:stage-error err})))
  {:repositories kept :interrupted? interrupted?})

(defn- select-in
  "Select from the catalog in `directory`, as `select` describes."
  [directory options chosen settings]
  (def list-filters (list-steps chosen))
  (def catalog
    (config/load-repository-catalog directory settings list-filters))
  # A placement whose filters could not run is only a problem to a command
  # that would have to read it, and a catalog-only selection reads none.
  (when (and (options :at-path) (not (options :catalog-only?)))
    (when-let [needed (first (location/broken-at (options :at-path) (catalog :broken)
                                                 (options :all-anchors?)))]
      (error (needed :message))))
  (cond
    (and (empty? (catalog :repository-lists)) (empty? (catalog :inline-lists)))
    {:repositories [] :catalog catalog :chosen chosen
     :reason {:kind :unconfigured :directory directory}}

    (options :catalog-only?)
    {:repositories [] :catalog catalog :chosen chosen}

    (do
      (def repositories (catalog :repositories))
      (def anchors (if (options :all-anchors?)
                     (location/configured-anchors repositories)
                     (location/containing-anchors (options :at-path) repositories)))
      (def located (location/locate-repositories-under-anchors
                     (options :at-path) repositories anchors))
      # Sampling costs a checksum, so it comes before the stages, which look
      # into the checkouts.
      (def sampled (if-let [bounds (options :sample)]
                     (sample/keep-sample located bounds)
                     located))
      (def commands (checkout-steps chosen))
      (def narrowed (narrow-by-stages options sampled commands (get settings :shell)))
      (def selected (narrowed :repositories))
      (if (narrowed :interrupted?)
        {:repositories [] :catalog catalog :chosen chosen :interrupted? true}
        {:repositories selected
         :catalog catalog
         :chosen chosen
         :reason (when (empty? selected)
                   (cond
                     (empty? located)
                     (why-empty options list-filters settings repositories anchors)
                     (empty? sampled)
                     {:kind :emptied-by-sample
                      :of (length located)
                      :sample (options :sample)}
                     {:kind :emptied-by-state
                      :of (length sampled)
                      :requested-state (options :requested-state)
                      :command-flags (distinct (map (fn [step] (if (step :exclude?) "-x" "-f"))
                                                    commands))}))}))))

(defn select
  ``Select the repositories that `options` ask for from the catalog `settings`
  describe.

  `options` holds `:at-path`, the working location, and `:directory`, where the
  configuration lives. `:all-anchors?` considers every anchor, not just those
  containing the location. `:filter-values` are the filter steps given with
  -f and -x, in the order given. A list filter narrows every repository
  list, and the rest are checkout filters or commands. `:chosen` of the
  result holds the steps as resolve-filters returns them.
  `:sample`, a `[low high]` range of percentages, keeps only the repositories
  sample/sampled? picks.
  `:requested-state`, :dirty or :clean, and
  the commands then narrow the repositories further, with `:jobs` at a time,
  and `:interrupted?` in the result says a stage was interrupted, in which case
  no repositories are picked. `:catalog-only?` loads the catalog and runs no
  stage.``
  [options settings]
  (def chosen (resolve-filters (get options :filter-values []) settings))
  (def directory (or (options :directory) (config/config-directory)))
  (def mistyped (first (steps-of-kind chosen :mistyped)))
  (cond
    mistyped
    {:repositories []
     :reason {:kind :mistyped-filter
              :value (mistyped :name)
              :known (named-filters/filter-names (get settings :filters {}))}}

    (nil? directory)
    {:repositories [] :reason {:kind :no-config-directory}}

    (select-in directory options chosen settings)))
