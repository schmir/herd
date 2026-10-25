# Choosing the repositories a command acts on, and saying why there are none.

(import ./config)
(import ./named-filters)
(import ./location)
(import ./process)
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
  ``Sort the -f `values`, in order. A name of a list filter in `settings`
  narrows the lists. A name of a checkout filter stands for its command, and
  anything else is taken to be a shell command itself. The commands run in the
  checkouts, so they follow the names. `:checkout-values` holds what was
  written for each command, for a message to quote. Return `{:mistyped value}`
  for the first value that is neither a filter nor a command.``
  [values settings]
  (def registry (get settings :filters {}))
  (def list-filters @[])
  (def checkout-commands @[])
  (def checkout-values @[])
  (var mistyped nil)
  (each value values
    (cond
      (named-filters/list-filter? registry value)
      (array/push list-filters value)
      (and (nil? (named-filters/checkout-filter-command registry value))
           (mistyped? value))
      (do (set mistyped value) (break))
      (do
        (array/push checkout-commands
                    (or (named-filters/checkout-filter-command registry value)
                        value))
        (array/push checkout-values value))))
  (if mistyped
    {:mistyped mistyped}
    {:list-filters list-filters
     :checkout-commands checkout-commands
     :checkout-values checkout-values}))

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
    {:kind :emptied-by-filters :list-filters list-filters}

    (empty? repositories) {:kind :empty-catalog}

    (empty? anchors)
    {:kind :no-anchor-contains-path :at-path (options :at-path)}

    {:kind :none-beneath-path :at-path (options :at-path)}))

(defn- narrow-by-stages
  ``Keep the `repositories` in the `:requested-state` that `options` asks for,
  and where the checkout filter `commands` succeed. An interrupt during a stage
  ends the selection there, since what it kept is only some of what it would
  have. Return `{:repositories :interrupted?}`.``
  [options repositories commands]
  (var kept repositories)
  (var interrupted? false)
  (try
    (do
      (when (options :requested-state)
        (def stage (stages/filter-by-state kept (options :requested-state)
                                           (options :jobs)))
        (set kept (stage :repositories))
        (set interrupted? (stage :interrupted?)))
      (when (and (not interrupted?) (not (empty? commands)))
        (def stage (stages/filter-by-commands kept commands (options :jobs)))
        (set kept (stage :repositories))
        (set interrupted? (stage :interrupted?))))
    ([err] (error {:stage-error err})))
  {:repositories kept :interrupted? interrupted?})

(defn- select-in
  "Select from the catalog in `directory`, as `select` describes."
  [directory options chosen settings]
  (def list-filters (chosen :list-filters))
  (def catalog
    (config/load-repository-catalog directory settings list-filters))
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
      (def commands (chosen :checkout-commands))
      (def narrowed (narrow-by-stages options located commands))
      (def selected (narrowed :repositories))
      (if (narrowed :interrupted?)
        {:repositories [] :catalog catalog :chosen chosen :interrupted? true}
        {:repositories selected
         :catalog catalog
         :chosen chosen
         :reason (when (empty? selected)
                   (if (empty? located)
                     (why-empty options list-filters settings repositories anchors)
                     {:kind :emptied-by-state
                      :of (length located)
                      :requested-state (options :requested-state)
                      :commands? (not (empty? commands))}))}))))

(defn select
  ``Select the repositories that `options` ask for from the catalog `settings`
  describe.

  `options` holds `:at-path`, the working location, and `:directory`, where the
  configuration lives. `:all-anchors?` considers every anchor, not just those
  containing the location. `:filter-values` are the values
  given with -f: a list filter narrows every repository list, and the rest
  are checkout filters or commands, which `:chosen` of the result lists.
  `:requested-state`, :dirty or :clean, and
  the commands then narrow the repositories further, with `:jobs` at a time,
  and `:interrupted?` in the result says a stage was interrupted, in which case
  no repositories are picked. `:catalog-only?` loads the catalog and runs no
  stage.``
  [options settings]
  (def chosen (resolve-filters (get options :filter-values []) settings))
  (def directory (or (options :directory) (config/config-directory)))
  (cond
    (chosen :mistyped)
    {:repositories []
     :reason {:kind :mistyped-filter
              :value (chosen :mistyped)
              :known (named-filters/filter-names (get settings :filters {}))}}

    (nil? directory)
    {:repositories [] :reason {:kind :no-config-directory}}

    (select-in directory options chosen settings)))
