# Compose repository selection phases without owning command-line behavior.

(import ./location)
(import ./state)

(defn by-location
  ``Return the repositories and anchors selected by `at`. When
  `all-anchors` is true, every repository is considered.``
  [at all-anchors repositories]
  (def anchors (unless all-anchors (location/containing-anchors at repositories)))
  {:anchors anchors
   :repositories (location/select-repositories-with-anchors
                   at repositories all-anchors anchors)})

(defn by-state
  ``Apply the requested repository state and shell-command stages in order.
  Call `after-stage` after each completed stage so the caller can preserve
  interruption handling between stages.``
  [repositories wanted commands jobs &opt after-stage]
  (var kept repositories)
  (when wanted
    (set kept (state/filter-by-state kept wanted jobs))
    (when after-stage (after-stage)))
  (unless (empty? commands)
    (set kept (state/filter-by-commands kept commands jobs))
    (when after-stage (after-stage)))
  kept)
