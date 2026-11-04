# Running an operation on each repository in parallel, with progress.

(import spork/rawterm)
# By bare name, not `./terminal`: jpm puts the build directory on the native
# module path only for names that are neither relative nor absolute.
(import terminal)

(def default-jobs
  "Number of repository operations allowed to run at the same time."
  6)

(def spinner-frames
  "Frames cycled through beside each active repository."
  ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"])

(defn terminal-width
  ``Usable columns of the terminal `stream` writes to, stdout unless given,
  falling back to 80 when the size is unknown.``
  [&opt stream]
  (def columns (terminal/columns (or stream stdout)))
  (if (and columns (< 20 columns 1000)) columns 80))

(def max-jobs
  ``The largest usable job count. `jobs?` accepts what `int?` does, which is
  what fits in an int32, so this is where a count stops being one.``
  2147483647)

(defn jobs?
  ``Whether `job-count` is a usable number of operations to run at the same
  time. The count bounds the slot loop in progress-lines, where a
  non-integer never ends it, so every caller weighs a count against this
  before any clamping could hide a bad one.``
  [job-count]
  (and (int? job-count) (pos? job-count)))

(defn- require-jobs
  "Return `jobs` unchanged, or raise when it is not a usable count."
  [jobs]
  (unless (jobs? jobs)
    (error "jobs must be a positive integer"))
  jobs)

(def interrupt-exit-code
  ``Status a run interrupted from the terminal exits with, as a shell reports
  a process SIGINT ended: 128 plus the signal.``
  130)

(defn make-progress
  "Create the state for one parallel repository run."
  [total outcomes &opt jobs live?]
  (default jobs default-jobs)
  (default live? (os/isatty stderr))
  (require-jobs jobs)
  (def counts @{})
  (each [key] outcomes
    (put counts key 0))
  @{:total total
    :jobs jobs
    :outcomes outcomes
    :counts counts
    # Each busy worker slot's repository path and when it began on it.
    :active @{}
    :frame 0
    :drawn 0
    :running? true
    :interrupted? false
    :live? live?})

(defn- erase
  "Remove the drawn block, leaving the cursor where it began."
  [progress]
  (when (pos? (progress :drawn))
    (eprinf "\e[%dA\e[J" (progress :drawn))
    (put progress :drawn 0)))

(defn fit-path
  "Trim a path from the left while preserving its distinguishing tail."
  [path width]
  (def segments (string/split "/" path))
  (var text path)
  (var index 0)
  (while (and (> (rawterm/monowidth text) width)
              (< (inc index) (length segments)))
    (++ index)
    (set text (string "…/" (string/join (slice segments index) "/"))))
  (if (> (rawterm/monowidth text) width)
    (string (rawterm/slice-monowidth text width))
    text))

(defn- tally
  ``The number of repositories with an outcome so far, and what each outcome
  counted: "2 succeeded, 1 failed", in the order the outcomes were declared.``
  [progress]
  (var completed 0)
  (def fields @[])
  (each [key label] (progress :outcomes)
    (def outcome-count (get (progress :counts) key))
    (+= completed outcome-count)
    (array/push fields (string outcome-count " " label)))
  [completed (string/join fields ", ")])

(defn format-elapsed
  ``A running time of `seconds` as a short label: "42s" under a minute,
  "3m07s" under an hour, and "2h05m" beyond.``
  [seconds]
  (def whole (math/floor (max 0 seconds)))
  (def minutes (div whole 60))
  (cond
    (< whole 60) (string/format "%ds" whole)
    (< whole 3600) (string/format "%dm%02ds" minutes (% whole 60))
    (string/format "%dh%02dm" (div minutes 60) (% minutes 60))))

(def elapsed-width
  ``Columns of the field the running time is right-aligned in, as wide as
  the longest label format-elapsed gives under 100 hours, "59m59s" or
  "99h59m", so the paths beside it line up.``
  6)

(def quiet-seconds
  ``How long a repository runs before its row shows the time, so only one
  that is slow to finish draws attention to itself.``
  5)

(defn progress-lines
  ``Render the active repositories, each with how long it has been running at
  `now`, a monotonic clock reading taken when not given, and the generic
  outcome tally.``
  [progress width &opt now]
  (default now (os/clock :monotonic))
  (def frame (spinner-frames (% (progress :frame) (length spinner-frames))))
  (def lines @[])
  (for slot 0 (progress :jobs)
    (when-let [{:path path :started started} (get (progress :active) slot)]
      (def seconds (- now started))
      (def label (if (<= seconds quiet-seconds) "" (format-elapsed seconds)))
      # A label wider than the field, from 100 hours on, pushes the path over.
      (def padding (max 0 (- elapsed-width (length label))))
      (def elapsed (string (string/repeat " " padding) label " "))
      (array/push lines
                  (string frame " " elapsed
                          (fit-path path (- width 2 (length elapsed)))))))
  (def [completed counted] (tally progress))
  (array/push lines
              (string (rawterm/slice-monowidth
                        (string completed "/" (progress :total) "  " counted)
                        width)))
  lines)

(defn- draw
  "Repaint the live block when stderr is a terminal."
  [progress]
  (when (progress :live?)
    (erase progress)
    # Leave one column unused so a line cannot wrap and break cursor tracking.
    (def width (dec (terminal-width stderr)))
    (def lines (progress-lines progress width))
    (each line lines
      (eprin line)
      (eprin "\n"))
    (put progress :drawn (length lines))
    (file/flush stderr)))

(defn- report
  ``Write one message to `stream`, a file or a buffer, above the live block,
  then redraw it. A file is flushed first, so one that is not a terminal
  cannot hold the message back past the block drawn after it.``
  [progress stream & xs]
  (erase progress)
  (xprint stream ;xs)
  (when (= :core/file (type stream))
    (file/flush stream))
  (draw progress))

(defn- animate
  "Cycle the spinner until the repository run finishes."
  [progress]
  (when (progress :live?)
    (ev/spawn
      (while (progress :running?)
        (ev/sleep 0.08)
        # The run can finish while this fiber sleeps.
        (when (progress :running?)
          (update progress :frame inc)
          (draw progress))))))

(defn- watch-for-interrupt
  ``Take over SIGINT for the duration of a run, so an interrupt winds the run
  down rather than being ignored: a standalone binary built by jpm installs
  none of the handling the interpreter does, and removing a handler again
  leaves the signal ignored rather than restoring the default. During a run
  the first interrupt stops it claiming repositories; asked a second time, or
  asked once the run is over, there is nothing left to wind down and this
  exits.``
  [progress]
  (os/sigaction :int
                (fn []
                  (when (or (progress :interrupted?) (not (progress :running?)))
                    (erase progress)
                    (file/flush stderr)
                    (os/exit interrupt-exit-code))
                  (put progress :interrupted? true))))

(defn for-each-repository
  ``Run `operation` for each repository with at most `jobs` active callbacks.
  `outcomes` lists the `[key label]` pairs a repository can end in. The
  callback receives the repository and a reporter, and returns an outcome
  key. Errors and unknown outcomes count as :failed. The live progress block
  is drawn when stderr is a terminal, unless `live?` is given: false keeps the
  run silent, apart from what it reports. `stop?`, when given, is asked before
  each repository is claimed, and once it answers true nothing more is.
  What the callback reports goes to `output`, a file or a buffer, stderr
  unless given; what goes wrong in running it is reported on stderr.

  Return `{:counts :interrupted? :stopped? :summary}`: how many repositories
  ended in each outcome, whether the terminal asked the run to stop, whether
  `stop?` did while repositories were left, in either case repositories it had
  not begun were left alone, and the counts as a line, "2 succeeded, 1
  failed", in the order the outcomes were declared. Saying that `stop?` ended
  the run is left to the caller, which knows what it was counting.``
  [repositories outcomes operation &opt jobs live? stop? output]
  (unless (some (fn [[key]] (= :failed key)) outcomes)
    (error "repository outcomes must include :failed"))
  (default output stderr)
  (def total (length repositories))
  # Only an absent count falls back, so a supplied bad one still raises.
  (default jobs default-jobs)
  (require-jobs jobs)
  # More workers than repositories would only draw empty spinner rows.
  (def workers (max 1 (min jobs total)))
  (def progress (make-progress total outcomes workers live?))
  (def cursor @[0])
  (watch-for-interrupt progress)
  (defn stopping? []
    (or (progress :interrupted?) (and stop? (stop?))))
  (defn worker [slot]
    # An interrupted run finishes what is in flight and claims nothing more.
    # A clone killed halfway leaves a checkout worse than a slow exit does.
    (while (and (not (stopping?)) (< (cursor 0) total))
      # Claiming an index does not yield, so workers cannot claim it twice.
      (def index (cursor 0))
      (put cursor 0 (inc index))
      (def repository (repositories index))
      (put (progress :active) slot {:path (repository :path)
                                    :started (os/clock :monotonic)})
      (draw progress)
      (var outcome
        (try
          (operation repository (fn [& args] (report progress output ;args)))
          ([err]
            (report progress stderr (repository :path) ": " err)
            :failed)))
      (when (nil? (get (progress :counts) outcome))
        (report progress stderr (repository :path) ": operation returned unknown outcome " outcome)
        (set outcome :failed))
      (put (progress :active) slot nil)
      (update (progress :counts) outcome inc)
      (draw progress)))
  (animate progress)
  (defer
    (do
      (put progress :running? false)
      (erase progress)
      (file/flush stderr))
    (ev/go-gather (seq [slot :range [0 workers]] (fn [] (worker slot)))))
  (def reached (reduce + 0 (values (progress :counts))))
  (def stopped? (and (not (progress :interrupted?)) (< reached total)))
  (when (progress :interrupted?)
    (eprint "Interrupted after " reached " of " total " repositories"))
  {:counts (progress :counts)
   :interrupted? (progress :interrupted?)
   :stopped? stopped?
   :summary ((tally progress) 1)})
