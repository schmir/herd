# Checking what argparse lets through, which it does not see for itself.

(defn flag-given-value
  ``The name of the first flag `args` hands a value with --name=VALUE, or nil.
  argparse accepts the form for a flag and then drops the value, so
  --all-anchors=no would turn the flag on. The scan follows argparse through
  `args`: an option given as --name or in a cluster of short flags takes the
  next argument as its value, and options end at `--` or, where the
  positional arguments stop parsing, at the first of those.``
  [args options]
  (def shorts (tabseq [[name handler] :pairs options
                       :when (handler :short)]
                ((handler :short) 0) name))
  (defn takes-value? [name]
    (index-of (get-in options [name :kind]) [:option :accumulate]))
  (var i 1)
  (var found nil)
  (while (and (nil? found) (< i (length args)))
    (def arg (args i))
    (++ i)
    (cond
      (= "--" arg) (break)
      (string/has-prefix? "--" arg)
      (let [[name & value] (string/split "=" (string/slice arg 2))]
        (cond
          (empty? value) (when (takes-value? name) (++ i))
          (= :flag (get-in options [name :kind])) (set found name)))
      (string/has-prefix? "-" arg)
      (each flag (string/slice arg 1)
        (when (takes-value? (shorts flag)) (++ i)))
      (get-in options [:default :short-circuit]) (break)))
  found)

(defn version-requested?
  ``Whether `args` asks for the version. Only the very first argument can: the
  flag carries no value, and whatever follows it is either a command name,
  which owns its own options, or a mistake. Everything else is left to
  argparse, which owns the usage errors and the help text.``
  [args]
  (def arg (get args 1))
  (cond
    (nil? arg) false
    # --version=VALUE is left to argparse, so that it rejects the value.
    (string/has-prefix? "--" arg) (= "--version" arg)
    # A cluster of short flags asks for the version only when that is all it
    # asks for: -hV wants the help argparse prints, and -Vx is a mistake.
    (and (string/has-prefix? "-" arg) (> (length arg) 1))
    (all (fn [character] (= character (chr "V"))) (string/slice arg 1))
    false))

(defn config-given
  ``The configuration -c or --config names in `args`, or nil. Only the
  options before the command name are bare herd's, and the last one given
  wins, as argparse has it. The configuration is needed before argparse runs,
  since the commands it defines are part of what argparse is told, so the
  scan follows argparse through those options: -c in a cluster of short
  flags takes the next argument, and options end at `--` or the command.
  A -c with no value is left for argparse to refuse.``
  [args]
  (var i 1)
  (var found nil)
  (while (< i (length args))
    (def arg (args i))
    (++ i)
    (cond
      (= "--" arg) (break)
      (string/has-prefix? "--config=" arg) (set found (string/slice arg 9))
      (= "--config" arg) (do (set found (get args i)) (++ i))
      (string/has-prefix? "--" arg) nil
      (string/has-prefix? "-" arg)
      (each flag (string/slice arg 1)
        (when (= flag (chr "c"))
          (set found (get args i))
          (++ i)))
      (break)))
  found)
