# The named filters, and narrowing a repository list with them.

(import spork/json)
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
  (string "a filter named with -f is applied to every configured list, and a "
          "field a list does not carry reads as null, which most JMESPath "
          "functions reject rather than treat as no match; naming it as "
          "`field || ''` gives them a string to work with"))

(def- filter-kinds
  "What a filter can be: a JMESPath expression, or a shell command."
  [:jp :sh])

(defn- validate-filter-entry
  ``Validate one `:filters` entry. A string is a JMESPath expression. A
  dictionary says what it is: `{:jp expression}` or `{:sh command}`, exactly
  one of them.``
  [name entry]
  (def label (filter-where name))
  (cond
    (string? entry)
    (when (empty? entry)
      (error (string label " needs a non-empty expression")))

    (dictionary? entry)
    (do
      (eachk key entry
        (unless (index-of key filter-kinds)
          (error (string label " has an unknown key " (describe key)))))
      (def kinds (seq [kind :in filter-kinds :when (has-key? entry kind)] kind))
      (unless (= 1 (length kinds))
        (error (string label " needs exactly one of :jp and :sh")))
      (def text (entry (first kinds)))
      (unless (and (string? text) (not (empty? text)))
        (error (string label " needs a non-empty string in " (describe (first kinds))))))

    (error (string label " needs an expression, or a dictionary with :jp or :sh"))))

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
  "Each name in `registry` with the expression or command it stands for."
  [registry]
  (table/to-struct
    (tabseq [[name entry] :pairs registry]
      name (or (text-of-kind entry :jp) (text-of-kind entry :sh)))))

(defn require-list-filters
  ``Raise unless every one of `names`, a row's `:filter`, is a list filter in
  `registry`. A checkout filter cannot narrow a list, since it runs in a
  checkout, so only the command line can use one. `where` says whose names
  they are. Return `names`.``
  [registry names where]
  (each name names
    (cond
      (list-filter? registry name) nil
      (checkout-filter-command registry name)
      (error (string where " names the command filter " (describe name)
                     ", which only the command line can use"))
      (error (string where " names an unknown filter " (describe name)))))
  names)

(defn apply-filter
  ``Return the JSON `source` narrowed by the JMESPath `expression` that `name`
  stands for, as the JSON the filter answered with. Bytes go in and bytes come
  back, never Janet values: decoding and re-encoding would round numbers to
  what a double can hold and reorder every object key, so an expression would
  no longer see the list as it is written on disk. A `hint` is added to the
  failure when the filter was named somewhere the list itself never asked
  for.``
  [source name expression &opt hint]
  (def executable
    (or (process/find-executable filter-executable)
        (error (string (filter-where name) " needs " filter-executable
                       " on PATH"))))
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
    (let [result (process/capture-process [executable "--" expression] : {:in input})
          stdout (result :out)
          stderr (result :err)]
      (unless (zero? (result :status))
        (error (string (filter-where name) " failed: "
                       (string/trimr (if (empty? stderr) stdout stderr))
                       (if hint (string "\n" hint) ""))))
      # Decoded only to be looked at: an expression that is not a filter answers
      # with null rather than failing, which would otherwise select nothing
      # without saying why. What travels on is what the filter wrote.
      (def answered
        (try
          (json/decode stdout true)
          ([err] (error (string (filter-where name)
                                " produced unreadable output: " err)))))
      (unless (indexed? answered)
        (error (string (filter-where name)
                       " did not select an array of repositories")))
      # A string rather than the buffer that was read into: what comes back
      # travels on to the next filter and must not be quietly mutable.
      (string stdout))))

(defn apply-filters
  ``Return the JSON `source` narrowed by each filter in `names`, in order.
  They run as a pipeline, each reading what the one before it answered with,
  the way piping one filter program into another does. Several `[?…]`
  expressions therefore intersect and commute; anything else, a slice or a
  projection, depends on its place in the order. Naming none hands back the
  source untouched, and the `hint` is carried to whichever of them fails.``
  [source names registry &opt hint]
  (var narrowed source)
  (each name names
    (set narrowed (apply-filter narrowed name
                                (list-filter-expression registry name) hint)))
  narrowed)

(defn narrow
  ``Return the JSON `source` narrowed by the list filters of `registry` that a
  row names, `row-names`, and then by those named with -f, `command-line-names`.
  A row aimed its own filters at this one file; the command line aimed its
  filters at every file, so only those explain themselves when they fail.``
  [registry source row-names command-line-names]
  (apply-filters (apply-filters source row-names registry)
                 command-line-names registry command-filter-hint))
