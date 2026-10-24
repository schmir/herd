# Running an operation on each repository in parallel, with progress.

(import spork/rawterm)

(def default-jobs
  "Number of repository operations allowed to run at the same time."
  6)

(def spinner-frames
  "Frames cycled through beside each active repository."
  ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"])

(defn terminal-width
  "Usable terminal columns, falling back to 80 when the size is unknown."
  []
  (def [_ columns] (try (rawterm/size) ([_] [0 0])))
  (if (< 20 columns 1000) columns 80))

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

(defn progress-lines
  "Render the active repositories and generic outcome tally."
  [progress width]
  (def frame (spinner-frames (% (progress :frame) (length spinner-frames))))
  (def lines @[])
  (for slot 0 (progress :jobs)
    (when-let [path (get (progress :active) slot)]
      (array/push lines (string frame " " (fit-path path (- width 2))))))
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
    (def width (dec (terminal-width)))
    (def lines (progress-lines progress width))
    (each line lines
      (eprin line)
      (eprin "\n"))
    (put progress :drawn (length lines))
    (file/flush stderr)))

(defn- report
  "Write one message above the live block, then redraw it."
  [progress & xs]
  (erase progress)
  (eprint ;xs)
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
  run silent, apart from what it reports.

  Return `{:counts :interrupted? :summary}`: how many repositories ended in
  each outcome, whether the terminal asked the run to stop, in which case
  repositories it had not begun were left alone, and the counts as a line,
  "2 succeeded, 1 failed", in the order the outcomes were declared.``
  [repositories outcomes operation &opt jobs live?]
  (unless (some (fn [[key]] (= :failed key)) outcomes)
    (error "repository outcomes must include :failed"))
  (def total (length repositories))
  # Only an absent count falls back, so a supplied bad one still raises.
  (default jobs default-jobs)
  (require-jobs jobs)
  # More workers than repositories would only draw empty spinner rows.
  (def workers (max 1 (min jobs total)))
  (def progress (make-progress total outcomes workers live?))
  (def cursor @[0])
  (watch-for-interrupt progress)
  (defn worker [slot]
    # An interrupted run finishes what is in flight and claims nothing more.
    # A clone killed halfway leaves a checkout worse than a slow exit does.
    (while (and (not (progress :interrupted?)) (< (cursor 0) total))
      # Claiming an index does not yield, so workers cannot claim it twice.
      (def index (cursor 0))
      (put cursor 0 (inc index))
      (def repository (repositories index))
      (put (progress :active) slot (repository :path))
      (draw progress)
      (var outcome
        (try
          (operation repository (fn [& args] (report progress ;args)))
          ([err]
            (report progress (repository :path) ": " err)
            :failed)))
      (when (nil? (get (progress :counts) outcome))
        (report progress (repository :path) ": operation returned unknown outcome " outcome)
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
  (when (progress :interrupted?)
    (eprint "Interrupted after " reached " of " total " repositories"))
  {:counts (progress :counts)
   :interrupted? (progress :interrupted?)
   :summary ((tally progress) 1)})
