# Compose repository selection phases without owning command-line behavior.

(import ./location)
(import ./state)

(defn by-location
  ``Return the repositories configured under one of the `selected-anchors` that
  are at `at-path`, beneath it or holding it.``
  [at-path repositories selected-anchors]
  (location/select-repositories-with-anchors at-path repositories
                                             selected-anchors))

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
