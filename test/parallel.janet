# Tests for parallel repository scheduling and progress rendering.
(use spork/test)
(import spork/rawterm)
(import ../src/parallel)

(start-suite "parallel")

(def outcomes
  [[:succeeded "succeeded"]
   [:skipped "skipped"]
   [:failed "failed"]])

(def repositories
  (map |{:path (string "/repo/" $) :clone-url "unused"} (range 12)))

(var active 0)
(var most-active 0)
(def seen @[])
(def result
  (parallel/for-each-repository
    repositories outcomes
    (fn [repository report]
      (++ active)
      (set most-active (max most-active active))
      (ev/sleep 0.001)
      (array/push seen (repository :path))
      (-- active)
      :succeeded)))

(assert (= 12 ((result :counts) :succeeded)) "every successful operation is counted")
(assert (= 12 (length seen)) "every repository runs once")
(assert (= 12 (length (distinct seen))) "no repository runs twice")
(assert (= parallel/default-jobs most-active)
        "the runner uses every worker by default")

(var limited-active 0)
(var limited-most-active 0)
(def limited
  (parallel/for-each-repository
    repositories outcomes
    (fn [repository report]
      (++ limited-active)
      (set limited-most-active (max limited-most-active limited-active))
      (ev/sleep 0.001)
      (-- limited-active)
      :succeeded)
    2))

(assert (= 12 ((limited :counts) :succeeded)) "a job limit still runs every repository")
(assert (= 2 limited-most-active) "a job limit bounds the active operations")

(var wide-most-active 0)
(var wide-active 0)
(parallel/for-each-repository
  (slice repositories 0 3) outcomes
  (fn [repository report]
    (++ wide-active)
    (set wide-most-active (max wide-most-active wide-active))
    (ev/sleep 0.001)
    (-- wide-active)
    :succeeded)
  8)

(assert (= 3 wide-most-active)
        "more jobs than repositories starts no idle workers")

(def completed @[])
(def failed
  (parallel/for-each-repository
    (slice repositories 0 3) outcomes
    (fn [repository report]
      (array/push completed (repository :path))
      (if (= "/repo/1" (repository :path))
        (error "planned failure")
        :succeeded))))

(assert (= 2 ((failed :counts) :succeeded)) "successful work continues after an error")
(assert (= 1 ((failed :counts) :failed)) "an operation error counts as a failure")
(assert (= 3 (length completed)) "an error does not stop later work")

(with [output (file/temp)]
  (parallel/for-each-repository
    (slice repositories 0 2) outcomes
    (fn [repository report]
      (if (= "/repo/1" (repository :path))
        (error "planned failure")
        (do (report "reported " (repository :path)) :succeeded)))
    1 false nil output)
  (file/seek output :set 0)
  (assert (= "reported /repo/0\n" (string (file/read output :all)))
          "what an operation reports goes to the given output, and its errors do not"))

(assert-error "a misplaced live flag is rejected instead of hanging"
              (parallel/make-progress 3 outcomes false))
(assert-error "a fractional job count is rejected"
              (parallel/make-progress 3 outcomes 1.5))

# Clamping the count to the repository total must not launder a bad value,
# so these reject regardless of how many repositories there are.
(each count [0 -2 1.5 false]
  (each total [1 5]
    (assert-error (string "for-each-repository rejects " count
                          " with " total " repositories")
                  (parallel/for-each-repository
                    (slice repositories 0 total) outcomes
                    (fn [repository report] :succeeded)
                    count))))

(def progress (parallel/make-progress 3 outcomes 1 false))
(put (progress :active) 0 {:path "/a/long/common/path/first" :started 100})
(put (progress :counts) :succeeded 1)
(put (progress :counts) :failed 1)
(def lines (parallel/progress-lines progress 32 165.5))

(assert (= 2 (length lines)) "progress has one active row and one tally")
(assert (string/has-prefix? "⠋ " (lines 0)) "an active row starts with a spinner")
(assert (= "⠋  1m05s …/common/path/first" (lines 0))
        "an active row shows how long its repository has been running, then its path")
(put (progress :active) 0 {:path "/a/long/common/path/first" :started 160})
(assert (= "⠋     5s …/common/path/first"
           ((parallel/progress-lines progress 32 165.5) 0))
        "a short running time is padded, so the paths line up")
(each started [165 160.5]
  (put (progress :active) 0 {:path "/a/long/common/path/first" :started started})
  (assert (= "⠋        …/common/path/first"
             ((parallel/progress-lines progress 32 165.5) 0))
          (string "a repository running " (- 165.5 started)
                  " seconds leaves the field blank")))
(assert (<= (rawterm/monowidth (lines 0)) 32)
        "the running time fits within the width, the path giving way")
(assert (= "2/3  1 succeeded, 0 skipped, 1 f"
           (lines 1))
        "the tally is truncated to the terminal width")
(each [seconds label] [[0 "0s"] [59.9 "59s"] [60 "1m00s"] [187 "3m07s"]
                       [3599 "59m59s"] [3600 "1h00m"] [7500 "2h05m"]]
  (assert (= label (parallel/format-elapsed seconds))
          (string seconds " seconds read as " label)))

# Below 100 hours every label fits the field the paths are lined up behind.
(each seconds [59 3599 (dec (* 100 3600))]
  (assert (<= (length (parallel/format-elapsed seconds)) parallel/elapsed-width)
          (string "the label for " seconds " seconds fits the field")))

(put (progress :active) 0 {:path "/a/long/common/path/first" :started 0})
(assert (= "⠋ 100h00m …/common/path/first"
           ((parallel/progress-lines progress 32 (* 100 3600)) 0))
        "a label wider than the field pushes the path over rather than failing")

(assert (= "…/common/path/first"
           (parallel/fit-path "/a/long/common/path/first" 20))
        "long paths keep their distinguishing tail")

# The rule every job count is weighed against, and the bound the messages
# naming it promise.
(each count [1 6 parallel/max-jobs]
  (assert (parallel/jobs? count)
          (string "a count of " count " is usable")))

(each count [0 -1 6.5 (+ parallel/max-jobs 1) "6" nil]
  (assert (not (parallel/jobs? count))
          (string (describe count) " is not a usable count")))

# A run nobody interrupted says so, whatever its outcomes were.
(assert (not (result :interrupted?)) "a completed run reports no interruption")
(assert (not (failed :interrupted?)) "and neither does one with a failure in it")

# The summary is the tally the progress block shows, in the order the outcomes
# were declared, so a command prints it rather than spelling the labels again.
(assert (= "12 succeeded, 0 skipped, 0 failed" (result :summary)))
(assert (= "2 succeeded, 0 skipped, 1 failed" (failed :summary)))

# stop? is asked before each claim: once it answers true, what is in flight
# finishes and nothing more is begun.
(def begun @[])
(def stopped
  (parallel/for-each-repository
    repositories outcomes
    (fn [repository report]
      (array/push begun (repository :path))
      (ev/sleep 0.001)
      :succeeded)
    2 false
    (fn [] (>= (length begun) 3))))

(assert (= 3 (length begun)) "no repository is claimed once stop? is true")
(assert (= 3 ((stopped :counts) :succeeded)) "what was begun is counted")
(assert (stopped :stopped?) "a run stop? ended early says so")
(assert (not (stopped :interrupted?)) "a stopped run was not interrupted")
(assert (not (result :stopped?)) "a run that reached every repository was not stopped")

(def stopped-at-end
  (parallel/for-each-repository
    (slice repositories 0 2) outcomes
    (fn [repository report] :succeeded)
    1 false
    (fn [] false)))
(assert (not (stopped-at-end :stopped?)) "a stop? that never answers true stops nothing")

# An interrupt winds the run down: what is in flight finishes, nothing more is
# begun, and the result says so. The operation sends the interrupt to this very
# process, which the run has taken the signal for.
(def interrupted
  (parallel/for-each-repository
    repositories outcomes
    (fn [repository report]
      (when (= "/repo/0" (repository :path))
        (os/execute ["kill" "-INT" (string (os/getpid))] :p))
      # The handler runs when the event loop gets its turn.
      (ev/sleep 0.05)
      :succeeded)
    1
    false))
(assert (interrupted :interrupted?) "an interrupted run says it was")
(def reached (reduce + 0 (values (interrupted :counts))))
(assert (and (pos? reached) (< reached 12))
        "the repository in flight finished and the rest were never begun")
(assert (= (string reached " succeeded, 0 skipped, 0 failed") (interrupted :summary))
        "the summary tells what was reached")

# Interrupting one run says nothing about the next.
(def again
  (parallel/for-each-repository (slice repositories 0 2) outcomes
                                (fn [repository report] :succeeded) 1 false))
(assert (not (again :interrupted?)) "a later run starts uninterrupted")
(assert (= 2 ((again :counts) :succeeded)) "and reaches every repository")

(with [f (file/temp)]
  (assert (= 80 (parallel/terminal-width f))
          "a stream with no terminal behind it is taken as 80 columns wide"))

(end-suite)
