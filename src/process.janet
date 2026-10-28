# Running a subprocess and collecting what it did.

# By bare name, not `./access`: jpm puts the build directory on the native
# module path only for names that are neither relative nor absolute.
(import access)

(defn find-executable
  "Find an executable file by searching the process PATH."
  [name]
  (some (fn [directory]
          (unless (empty? directory)
            (def candidate (string directory "/" name))
            (def info (os/stat candidate))
            # A directory carrying x is one that can be entered, and access
            # says as much, so being a file is still asked separately.
            (when (and info
                       (= :file (info :mode))
                       (access/executable? candidate))
              candidate)))
        (string/split ":" (os/getenv "PATH" ""))))

(defn capture
  ``Run `args` to completion and return what it did as `{:status :out :err}`.
  `flags` and `env` are os/spawn's, except that stdout and stderr are always
  pipes this reads: a child writing more than a pipe buffer holds would block
  forever on one nobody drains, so both are drained while it runs rather than
  after it exits. Unless `env` gives it an `:in`, the child finds standard
  input closed, since runs go on in parallel and a child sharing the terminal
  would interleave or hang the others. The process is closed on the way out,
  which closes those pipes; left to the garbage collector instead, a run over
  a few hundred repositories can hold open more descriptors than the process
  is allowed.``
  [args &opt flags env]
  (default flags :)
  (default env {})
  (with [process (os/spawn args flags
                           (merge {:in :pipe} env {:out :pipe :err :pipe}))]
    # The child has its end of whatever it reads. Ours is closed at once, which
    # is what ends the input of a child that was given a pipe, and spawn leaves
    # open a stream for one that was given a file.
    (when-let [input (process :in)]
      (:close input))
    (def stdout @"")
    (def stderr @"")
    (ev/gather
      (:read (process :out) :all stdout)
      (:read (process :err) :all stderr)
      (:wait process))
    {:status (process :return-code) :out stdout :err stderr}))

(def default-shell
  ``The argument vector a command string is run with, unless :shell in
  config.jdn names another.``
  ["sh" "-c"])

(defn shell-argv
  ``The argument vector that runs the shell `command` with `arguments` as its
  positional parameters, for the command to use as "$@", $1 and so on. They
  are never part of the shell's input. `shell` is the vector the command
  follows, `default-shell` unless given; its program is the command's $0.``
  [command arguments &opt shell]
  (default shell default-shell)
  [;shell command (first shell) ;arguments])
