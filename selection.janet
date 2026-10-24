# Choosing the repositories a command acts on, and saying why there are none.

(import ./config)
(import ./filter)
(import ./location)
(import ./process)
(import ./state)

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
  checkouts, so they follow the names. `:command-values` holds what was
  written for each command, for a message to quote. Return `{:mistyped value}`
  for the first value that is neither a filter nor a command.``
  [values settings]
  (def registry (get settings :filters {}))
  (def names @[])
  (def commands @[])
  (def command-values @[])
  (var mistyped nil)
  (each value values
    (cond
      (filter/list-filter? registry value) (array/push names value)
      (and (nil? (filter/command-for registry value)) (mistyped? value))
      (do (set mistyped value) (break))
      (do
        (array/push commands (or (filter/command-for registry value) value))
        (array/push command-values value))))
  (if mistyped
    {:mistyped mistyped}
    {:names names :commands commands :command-values command-values}))

(defn- filters-in-play?
  ``Whether any filter narrows this run, named on the command line or by a
  checkout row. An empty result is worth explaining only when something could
  have removed the repositories.``
  [names settings]
  (or (not (empty? names))
      (not (empty? (get-in settings [:defaults :filter] [])))
      (true? (some (fn [checkout-row] (not (empty? (get checkout-row :filter []))))
                   (get settings :checkouts [])))))

(defn- why-empty
  "The reason a selection from `repositories` picked nothing."
  [options names settings repositories anchors]
  (cond
    (and (empty? repositories) (filters-in-play? names settings))
    {:kind :emptied-by-filters :names names}

    (empty? repositories) {:kind :empty-catalog}

    (empty? anchors)
    {:kind :no-anchor-contains-path :at-path (options :at-path)}

    {:kind :none-beneath-path :at-path (options :at-path)}))

(defn- narrow-by-state
  ``Keep the `repositories` in the state `:wanted-state` of `options` asks for,
  and where the checkout filter `commands` succeed. An interrupt during a stage
  ends the selection there, since what it kept is only some of what it would
  have. Return `{:repositories :interrupted?}`.``
  [options repositories commands]
  (var kept repositories)
  (var interrupted? false)
  (try
    (do
      (when (options :wanted-state)
        (def stage (state/filter-by-state kept (options :wanted-state)
                                          (options :jobs)))
        (set kept (stage :repositories))
        (set interrupted? (stage :interrupted?)))
      (when (and (not interrupted?) (not (empty? commands)))
        (def stage (state/filter-by-commands kept commands (options :jobs)))
        (set kept (stage :repositories))
        (set interrupted? (stage :interrupted?))))
    ([err] (error {:stage-error err})))
  {:repositories kept :interrupted? interrupted?})

(defn- select-in
  "Select from the catalog in `directory`, as `select` describes."
  [directory options filters settings]
  (def names (filters :names))
  (def catalog (config/load-repository-catalog directory settings names))
  (cond
    (empty? (catalog :paths))
    {:repositories [] :catalog catalog :filters filters
     :reason {:kind :unconfigured :directory directory}}

    (options :catalog-only?)
    {:repositories [] :catalog catalog :filters filters}

    (do
      (def repositories (catalog :repositories))
      (def anchors (if (options :all-anchors?)
                     (location/configured-anchors repositories)
                     (location/containing-anchors (options :at-path) repositories)))
      (def located (location/select-repositories-with-anchors
                     (options :at-path) repositories anchors))
      (def commands (filters :commands))
      (def narrowed (narrow-by-state options located commands))
      (def selected (narrowed :repositories))
      (if (narrowed :interrupted?)
        {:repositories [] :catalog catalog :filters filters :interrupted? true}
        {:repositories selected
         :catalog catalog
         :filters filters
         :reason (when (empty? selected)
                   (if (empty? located)
                     (why-empty options names settings repositories anchors)
                     {:kind :emptied-by-state
                      :of (length located)
                      :wanted (options :wanted-state)
                      :commands? (not (empty? commands))}))}))))

(defn select
  ``Select the repositories that `options` ask for from the catalog `settings`
  describe.

  `options` holds `:at-path`, the working location, and `:directory`, where the
  configuration lives. `:all-anchors?` considers every anchor, not just those
  containing the location. `:filter-values` are the values
  given with -f: a list filter narrows every configuration file, and the rest
  are checkout filters or commands, which `:filters` of the result lists. `:wanted-state`, :dirty or :clean, and
  the commands then narrow the repositories further, with `:jobs` at a time,
  and `:interrupted?` in the result says a stage was interrupted, in which case
  no repositories are picked. `:catalog-only?` loads the catalog and runs no
  stage.``
  [options settings]
  (def filters (resolve-filters (get options :filter-values []) settings))
  (def directory (or (options :directory) (config/config-directory)))
  (cond
    (filters :mistyped)
    {:repositories []
     :reason {:kind :mistyped-filter
              :value (filters :mistyped)
              :known (filter/names (get settings :filters {}))}}

    (nil? directory)
    {:repositories [] :reason {:kind :no-config-directory}}

    (select-in directory options filters settings)))
