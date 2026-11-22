# The named filters, and narrowing a repository list with them.

(import spork/json)
(import ./checkout)
(import ./process)

(def filter-executable
  "Program that evaluates a filter expression."
  "jp")

(defn- filter-where
  "Name a filter in an error message."
  [name]
  (string "filter " (describe name)))

(def command-filter-hint
  ``Said when a filter named on the command line fails. A row aims its own
  filters at one file; -f meets every list, including those written without
  that filter in mind.``
  (string "a filter named with -f or -x is applied to every configured list, and a "
          "field a list does not carry reads as null, which most JMESPath "
          "functions reject rather than treat as no match; naming it as "
          "`field || ''` gives them a string to work with"))

(def- filter-kinds
  "What a filter can be: a JMESPath expression, or a shell command."
  [:jp :sh])

(defn- validate-filter-entry
  ``Validate one `:filters` entry. A string is a JMESPath expression. A
  dictionary says what it is: `{:jp expression}` or `{:sh command}`, exactly
  one of them. It can also hold `:doc`, the text that completions show for
  the filter. The text is one line, because completions give each filter one
  line.``
  [name entry]
  (def where (filter-where name))
  (cond
    (string? entry)
    (when (empty? entry)
      (error (string where " needs a non-empty expression")))

    (dictionary? entry)
    (do
      (eachk key entry
        (unless (index-of key [;filter-kinds :doc])
          (error (string where " has an unknown key " (describe key)))))
      (def kinds (seq [kind :in filter-kinds :when (has-key? entry kind)] kind))
      (unless (= 1 (length kinds))
        (error (string where " needs exactly one of :jp and :sh")))
      (def text (entry (first kinds)))
      (unless (and (string? text) (not (empty? text)))
        (error (string where " needs a non-empty string in " (describe (first kinds)))))
      (when (has-key? entry :doc)
        (def doc-text (entry :doc))
        (unless (and (string? doc-text) (not (empty? doc-text))
                     (not (string/find "\n" doc-text)))
          (error (string where " needs a non-empty string of one line in :doc")))))

    (error (string where " needs an expression, or a dictionary with :jp or :sh"))))

(defn validate-registry
  ``Validate the `:filters` registry and return it. It maps a filter name to
  what it stands for, a JMESPath expression or a shell command; every
  reference elsewhere names one of these, so a mistyped name is caught rather
  than silently selecting nothing.``
  [filters]
  (unless (dictionary? filters)
    (error ":filters must be a dictionary of names to filters"))
  (eachp [name entry] filters
    (unless (and (string? name) (not (empty? name)))
      (error "filter names must be non-empty strings"))
    (when (string/has-prefix? "!" name)
      (error (string (filter-where name) " starts with \"!\", which"
                     " :use-filters reads as excluding a filter")))
    (when (string/find ":" name)
      (error (string (filter-where name) " contains \":\", which -f reads"
                     " as the start of the arguments of a filter")))
    (validate-filter-entry name entry))
  filters)

(defn- text-of-kind
  "What the registry entry `entry` stands for if it is of `kind`, else nil."
  [entry kind]
  (if (string? entry)
    (when (= kind :jp) entry)
    (get entry kind)))

(defn- list-filter-expression
  "The JMESPath expression the list filter `name` stands for, or nil."
  [registry name]
  (text-of-kind (get registry name) :jp))

(defn list-filter?
  "Whether `name` is a list filter in `registry`: one that narrows a list."
  [registry name]
  (not (nil? (list-filter-expression registry name))))

(defn checkout-filter-command
  "The shell command the checkout filter `name` stands for, or nil."
  [registry name]
  (text-of-kind (get registry name) :sh))

(defn filter-names
  "Every filter name in `registry`, sorted."
  [registry]
  (sorted (keys registry)))

(defn descriptions
  ``Each name in `registry` with its `:doc`, or with the expression or command
  it stands for when it has no `:doc`.``
  [registry]
  (table/to-struct
    (tabseq [[name entry] :pairs registry]
      name (or (when (dictionary? entry) (entry :doc))
               (text-of-kind entry :jp)
               (text-of-kind entry :sh)))))

(defn step
  ``Make a filter step, `{:name :exclude?}`. `name` is the filter name or the
  command as written. With `exclude?`, the step leaves out what it matches.``
  [name &opt exclude?]
  {:name name :exclude? (truthy? exclude?)})

(defn row-step
  ``The filter step that `name`, from a row's `:use-filters`, stands for. A
  leading "!" makes it an exclusion.``
  [name]
  (if (string/has-prefix? "!" name)
    (step (string/slice name 1) true)
    (step name)))

(defn step-label
  "The filter step `step` as `:use-filters` writes it, with \"!\" for an exclusion."
  [step]
  (string (if (step :exclude?) "!" "") (step :name)))

(defn require-list-filters
  ``Raise unless every one of `names`, a row's `:use-filters`, names a list
  filter in `registry`, with or without a leading "!". A checkout filter
  cannot narrow a list, since it runs in a checkout, so only the command line
  can use one. `where` says whose names they are. Return `names`.``
  [registry names where]
  (each written names
    (def name ((row-step written) :name))
    (cond
      (list-filter? registry name) nil
      (checkout-filter-command registry name)
      (error (string where " names the command filter " (describe name)
                     ", which only the command line can use"))
      (error (string where " names an unknown filter " (describe name)))))
  names)

(defn executable-available?
  "Whether the program that evaluates a filter expression can be found."
  []
  (not (nil? (process/find-executable filter-executable))))

(defn missing-executable-message
  "What to say of the filter `name` when the program to run it is missing."
  [name]
  (string (filter-where name) " needs " filter-executable " on PATH"))

(defn apply-filter
  ``Return the repository list `entries`, decoded JSON, narrowed by the
  JMESPath `expression` that `name` stands for, as the decoded JSON the filter
  answered with. A `hint` is added to the failure when the filter was named
  somewhere the list itself never asked for.``
  [entries name expression &opt hint]
  (def executable
    (or (process/find-executable filter-executable)
        (error (missing-executable-message name))))
  # Decoded JSON can hold a number too large for a double, or a string that
  # is not valid UTF-8, and JSON cannot write either.
  (def source
    (try (json/encode entries)
      ([err] (error (string (filter-where name) " cannot be given the list: " err)))))
  # The list reaches the filter as its standard input, held in a file with no
  # name: nothing another user on this machine can find, open or replace, and
  # nothing left behind if herd is killed. A regular file rather than a pipe
  # is what matters here. A filter that rejects its expression never reads its
  # input, and a pipe nobody is draining would kill herd with SIGPIPE before it
  # could report what the filter said.
  (with [input (file/temp)]
    (file/write input source)
    # The child reads through the same file description, so it starts where
    # this leaves off unless the offset goes back to the beginning. Buffered
    # bytes are still ours until they are flushed.
    (file/flush input)
    (file/seek input :set 0)
    # "--" keeps an expression that starts with a dash from reading as an
    # option.
    (let [result (process/capture [executable "--" expression] : {:in input})
          stdout (result :out)
          stderr (result :err)]
      (unless (zero? (result :status))
        (error (string (filter-where name) " failed: "
                       (string/trimr (if (empty? stderr) stdout stderr))
                       (if hint (string "\n" hint) ""))))
      (def answered
        (try
          (json/decode stdout)
          ([err] (error (string (filter-where name)
                                " produced unreadable output: " err)))))
      # An expression that is not a filter answers with null rather than
      # failing, which would otherwise select nothing without saying why.
      (unless (indexed? answered)
        (error (string (filter-where name)
                       " did not select an array of repositories")))
      answered)))

(defn- repository-key
  ``The path and clone URL of the list entry `entry`, or nil when it does not
  have a string "path" and a string clone URL.``
  [entry]
  (when (dictionary? entry)
    (def url (entry (checkout/url-key entry)))
    (when (and (string? (entry "path")) (string? url))
      [(entry "path") url])))

(defn- leave-out
  ``Return the repository list `entries` without the entries whose path and
  clone URL are those of an entry in `matched`, what the filter `name`
  answered with. Both are decoded JSON. Comparing by these and not by the
  whole entry lets a projection that keeps them work as it does with -f.
  Every entry of `matched` must have them, so a filter that answers with
  something else is an error and does not exclude nothing.``
  [entries matched name]
  (unless (indexed? entries)
    (error (string (filter-where name)
                   " can only be excluded from an array of repositories")))
  (def keys-matched @{})
  (each entry matched
    (put keys-matched
         (or (repository-key entry)
             (error (string (filter-where name) " answered with an entry"
                            " without a string \"path\" and clone URL,"
                            " which an exclusion needs to compare entries")))
         true))
  (filter (fn [entry] (not (get keys-matched (repository-key entry))))
          entries))

(defn apply-filters
  ``Return the repository list `entries`, decoded JSON, narrowed by each
  filter step in `steps`, in order. A step with `:exclude?` keeps what its
  filter leaves out. They run as a
  pipeline, each reading what the one before it answered with, the way piping
  one filter program into another does. Several `[?…]` expressions therefore
  intersect and commute; anything else, a slice or a projection, depends on
  its place in the order. Naming none hands back `entries` untouched, and the
  `hint` is carried to whichever of them fails.``
  [entries steps registry &opt hint]
  (var narrowed entries)
  (each step steps
    (def name (step :name))
    (def answered (apply-filter narrowed name
                                (list-filter-expression registry name) hint))
    (set narrowed (if (step :exclude?)
                    (leave-out narrowed answered name)
                    answered)))
  narrowed)

(defn narrow
  ``Return the repository list `entries`, decoded JSON, narrowed by the list
  filter steps of a row, `row-steps`, and then by the filter steps given with
  -f and -x, `command-line-steps`. `registry` holds the list filters.
  A row aimed its own filters at this one file; the command line aimed its
  filters at every file, so only those explain themselves when they fail.``
  [registry entries row-steps command-line-steps]
  (apply-filters (apply-filters entries row-steps registry)
                 command-line-steps registry command-filter-hint))
