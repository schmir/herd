(import spork/rawterm)

(def worker-count
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

(defn make-progress
  "Create the state for one parallel repository run."
  [total outcomes &opt live]
  (default live (os/isatty stderr))
  (def counts @{})
  (each outcome outcomes
    (put counts (outcome 0) 0))
  @{:total total
    :outcomes outcomes
    :counts counts
    :active @{}
    :frame 0
    :drawn 0
    :running true
    :live live})

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

(defn progress-lines
  "Render the active repositories and generic outcome tally."
  [progress width]
  (def frame (spinner-frames (% (progress :frame) (length spinner-frames))))
  (def lines @[])
  (for slot 0 worker-count
    (when-let [path (get (progress :active) slot)]
      (array/push lines (string frame " " (fit-path path (- width 2))))))
  (var completed 0)
  (def fields @[])
  (each outcome (progress :outcomes)
    (def count (get (progress :counts) (outcome 0)))
    (+= completed count)
    (array/push fields (string count " " (outcome 1))))
  (array/push lines
              (string (rawterm/slice-monowidth
                        (string completed "/" (progress :total) "  "
                                (string/join fields "  "))
                        width)))
  lines)

(defn- draw
  "Repaint the live block when stderr is a terminal."
  [progress]
  (when (progress :live)
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
  (when (progress :live)
    (ev/spawn
      (while (progress :running)
        (ev/sleep 0.08)
        # The run can finish while this fiber sleeps.
        (when (progress :running)
          (update progress :frame inc)
          (draw progress))))))

(defn run-repositories
  ``Run `operation` for each repository with at most six active callbacks.
  The callback receives the repository and a reporter, and returns an outcome
  key. Errors and unknown outcomes count as :failed.``
  [repositories outcomes operation]
  (unless (some |(= :failed ($ 0)) outcomes)
    (error "repository outcomes must include :failed"))
  (def total (length repositories))
  (def progress (make-progress total outcomes))
  (def cursor @[0])
  (defn worker [slot]
    (while (< (cursor 0) total)
      # Claiming an index does not yield, so workers cannot claim it twice.
      (def index (cursor 0))
      (put cursor 0 (inc index))
      (def repository (repositories index))
      (put (progress :active) slot (repository :path))
      (draw progress)
      (var outcome
        (try
          (operation repository |(report progress ;$&))
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
      (put progress :running false)
      (erase progress)
      (file/flush stderr))
    (ev/go-gather (seq [slot :range [0 worker-count]] |(worker slot))))
  (progress :counts))
