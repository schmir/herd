# Running a subprocess and collecting what it did.

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

(defn capture-process
  ``Run `args` to completion and return what it did as `{:status :out :err}`.
  `flags` and `env` are os/spawn's, except that stdout and stderr are always
  pipes this reads: a child writing more than a pipe buffer holds would block
  forever on one nobody drains, so both are drained while it runs rather than
  after it exits. The process is closed on the way out, which closes those
  pipes; left to the garbage collector instead, a run over a few hundred
  repositories can hold open more descriptors than the process is allowed.``
  [args &opt flags env]
  (default flags :)
  (default env {})
  (with [process (os/spawn args flags (merge env {:out :pipe :err :pipe}))]
    (def stdout @"")
    (def stderr @"")
    (ev/gather
      (:read (process :out) :all stdout)
      (:read (process :err) :all stderr)
      (:wait process))
    {:status (process :return-code) :out stdout :err stderr}))
