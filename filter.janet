# Narrowing a repository list with the JMESPath expressions it is named by.

(import ./process)
(import ./entries)

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
          (entries/parse-config stdout)
          ([err] (error (string (filter-where name)
                                " produced unreadable output: " err)))))
      (unless (indexed? answered)
        (error (string (filter-where name)
                       " did not select an array of repositories")))
      # A string rather than the buffer that was read into: what comes back
      # travels on to the next filter and must not be quietly mutable.
      (string stdout))))

(defn filter-entries
  ``Return the JSON `source` narrowed by each filter in `names`, in order.
  They run as a pipeline, each reading what the one before it answered with,
  the way piping one filter program into another does. Several `[?…]`
  expressions therefore intersect and commute; anything else, a slice or a
  projection, depends on its place in the order. Naming none hands back the
  source untouched, and the `hint` is carried to whichever of them fails.``
  [source names filters &opt hint]
  (var narrowed source)
  (each name names
    (set narrowed (apply-filter narrowed name (get filters name) hint)))
  narrowed)
