(import spork/json)
(import spork/rawterm)

(def worker-count
  "Number of Git processes allowed to run at the same time."
  6)

(def spinner-frames
  "Frames cycled through beside each in-flight clone."
  ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"])

(defn find-executable
  "Find an executable file by searching the process PATH."
  [name]
  (some (fn [directory]
          (unless (empty? directory)
            (def candidate (string directory "/" name))
            (def info (os/stat candidate))
            (when (and info
                       (= :file (info :mode))
                       (string/find "x" (info :permissions)))
              candidate)))
        (string/split ":" (os/getenv "PATH" ""))))

(defn terminal-width
  "Usable terminal columns, falling back to 80 when the size is unknown."
  []
  (def [_ columns] (try (rawterm/size) ([_] [0 0])))
  (if (< 20 columns 1000) columns 80))

(defn make-progress
  ``State backing the live display. It only draws when stderr is a terminal,
  so redirected output stays plain.``
  [total]
  @{:total total
    :active @{}
    :cloned 0
    :skipped 0
    :failed 0
    :frame 0
    :drawn 0
    :running true
    :live (os/isatty stderr)})

(defn- erase
  "Remove the drawn block, leaving the cursor where it began."
  [progress]
  (when (pos? (progress :drawn))
    (eprinf "\e[%dA\e[J" (progress :drawn))
    (put progress :drawn 0)))

(defn- fit-path
  ``Trim path to `width` columns. Repository paths share long leading
  segments, so drop those first and keep the distinguishing tail.``
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

(defn- draw
  "Repaint the block: one line per busy worker, then a tally."
  [progress]
  (when (progress :live)
    (erase progress)
    # Truncate to one column short of the edge so no line wraps; a wrapped
    # line would make the cursor-up count in `erase` wrong.
    (def width (dec (terminal-width)))
    (def frame (spinner-frames (% (progress :frame) (length spinner-frames))))
    (def lines @[])
    (for slot 0 worker-count
      (when-let [path (get (progress :active) slot)]
        (array/push lines (string frame " " (fit-path path (- width 2))))))
    (array/push lines
                (string (rawterm/slice-monowidth
                          (string/format "%d/%d  %d cloned  %d already checked out  %d failed"
                                         (+ (progress :cloned) (progress :skipped) (progress :failed))
                                         (progress :total)
                                         (progress :cloned)
                                         (progress :skipped)
                                         (progress :failed))
                          width)))
    (each line lines
      (eprin line)
      (eprin "\n"))
    (put progress :drawn (length lines))
    (file/flush stderr)))

(defn- log
  "Write a line above the block, then redraw it."
  [progress & xs]
  (erase progress)
  (eprint ;xs)
  (draw progress))

(defn- animate
  "Cycle the spinner until the run finishes."
  [progress]
  (when (progress :live)
    (ev/spawn
      (while (progress :running)
        (ev/sleep 0.08)
        # :running may have been cleared while this fiber slept. Drawing after
        # the final erase would strand a stale block below the summary.
        (when (progress :running)
          (update progress :frame inc)
          (draw progress))))))

(defn checked-out?
  "Check whether path already holds a checkout."
  [path]
  (and (= :directory (os/stat path :mode))
       (not (empty? (os/dir path)))))

(defn checkout
  ``Clone a Git repository unless it is already checked out.
  Returns :skipped, :cloned or :failed.``
  [jj env progress path url]
  (if (checked-out? path)
    :skipped
    (try
      (do
        (def process (os/spawn [jj "git" "clone" "--colocate" url path] : env))
        (def stdout @"")
        (def stderr @"")
        (ev/gather
          (:read (process :out) :all stdout)
          (:read (process :err) :all stderr)
          (:wait process))
        (if (zero? (process :return-code))
            (do
              (log progress "Checkout complete: " path)
              :cloned)
            (do
              (log progress "Checkout failed: " path)
              (when (> (length stderr) 0) (log progress stderr))
              (when (> (length stdout) 0) (log progress stdout))
              :failed)))
      ([err]
        (log progress "Checkout failed: " path ": " err)
        :failed))))

(defn checkout-all
  ``Clone repositories, keeping at most `worker-count` Git processes active.
  Returns a struct of :cloned, :skipped and :failed counts.``
  [repositories]
  (def jj (find-executable "jj"))
  (def total (length repositories))
  (if (nil? jj)
    (do
      (eprint "jj was not found on PATH")
      {:cloned 0 :skipped 0 :failed total})
    # Clones must never inherit the terminal: several run at once, and a jj
    # or ssh prompt on a shared stdin would interleave or hang the whole run.
    (with [devnull (file/open "/dev/null" :r)]
      (def env {:in devnull :out :pipe :err :pipe})
      (def progress (make-progress total))
      (def cursor @[0])
      # Each worker claims the next index and moves on as soon as its own
      # clone finishes. Reading and advancing the cursor never yields, so
      # no two workers can claim the same index.
      (defn worker [slot]
        (while (< (cursor 0) total)
          (def index (cursor 0))
          (put cursor 0 (inc index))
          (def repository (repositories index))
          (put (progress :active) slot (repository :path))
          (draw progress)
          (def result (checkout jj env progress
                                (repository :path)
                                (repository :ssh_url)))
          (put (progress :active) slot nil)
          (update progress result inc)))
      (animate progress)
      (ev/go-gather (seq [slot :range [0 worker-count]] |(worker slot)))
      (put progress :running false)
      (erase progress)
      (file/flush stderr)
      {:cloned (progress :cloned)
       :skipped (progress :skipped)
       :failed (progress :failed)})))

(defn validate-config
  "Return config unchanged, or raise a descriptive error describing its shape."
  [config]
  (unless (indexed? config)
    (error "expected a JSON array of repository objects"))
  (for index 0 (length config)
    (def entry (config index))
    (unless (dictionary? entry)
      (error (string "entry " index " is not a JSON object")))
    (each key [:path :ssh_url]
      (unless (string? (entry key))
        (error (string "entry " index " needs a string \"" key "\"")))))
  config)

(defn parse-config
  "Parse JSON source into application configuration."
  [source]
  (json/decode source true))

(defn read-config
  "Read, parse and validate a JSON configuration file."
  [path]
  (validate-config (parse-config (slurp path))))

(defn main
  [& args]
  (def path (get args 1 "config.json"))
  (def config
    (try
      (read-config path)
      ([err]
        (eprint "Configuration error in " path ": " err)
        (os/exit 1))))
  (def counts (checkout-all config))
  (print (counts :cloned) " cloned, "
         (counts :skipped) " already checked out, "
         (counts :failed) " failed")
  (when (pos? (counts :failed))
    (os/exit 1)))
