# Showing what herd printed through a pager on a terminal.

(import ./process)

(defn page
  ``Show `text` through the `pager` command, run by `shell`, when it is
  colored for a terminal, unless the pager is false. The default, less,
  shows the color, quits at once when the text fits on the screen, and
  leaves it there when it quits. Without a pager, or when it cannot be
  started, the text is printed.

  An interrupt the reader types in the pager is the pager's, so from then on
  herd ignores SIGINT rather than ending under it. Nothing can put the
  default back, so page is the last thing herd does with the terminal.``
  [text color? pager &opt shell]
  (def pager
    (when (and pager color? (not (empty? text)))
      (try (os/spawn (process/shell-argv pager [] shell) :p {:in :pipe}) ([_] nil))))
  (if pager
    (do
      (os/sigaction :int (fn []))
      # The reader may quit before the end, which closes the pipe.
      (try (:write (pager :in) text) ([_] nil))
      (try (:close (pager :in)) ([_] nil))
      (os/proc-wait pager))
    (prin text)))
