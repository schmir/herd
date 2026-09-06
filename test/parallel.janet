# Tests for parallel repository scheduling and progress rendering.
(use spork/test)
(import ../parallel)

(start-suite "parallel")

(def outcomes
  [[:succeeded "succeeded"]
   [:skipped "skipped"]
   [:failed "failed"]])

(def repositories
  (map |{:path (string "/repo/" $) :ssh_url "unused"} (range 12)))

(var active 0)
(var most-active 0)
(def seen @[])
(def counts
  (parallel/run-repositories
    repositories outcomes
    (fn [repository report]
      (++ active)
      (set most-active (max most-active active))
      (ev/sleep 0.001)
      (array/push seen (repository :path))
      (-- active)
      :succeeded)))

(assert (= 12 (counts :succeeded)) "every successful operation is counted")
(assert (= 12 (length seen)) "every repository runs once")
(assert (= 12 (length (distinct seen))) "no repository runs twice")
(assert (= parallel/default-jobs most-active)
        "the runner uses every worker by default")

(var limited-active 0)
(var limited-most-active 0)
(def limited
  (parallel/run-repositories
    repositories outcomes
    (fn [repository report]
      (++ limited-active)
      (set limited-most-active (max limited-most-active limited-active))
      (ev/sleep 0.001)
      (-- limited-active)
      :succeeded)
    2))

(assert (= 12 (limited :succeeded)) "a job limit still runs every repository")
(assert (= 2 limited-most-active) "a job limit bounds the active operations")

(var wide-most-active 0)
(var wide-active 0)
(parallel/run-repositories
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
  (parallel/run-repositories
    (slice repositories 0 3) outcomes
    (fn [repository report]
      (array/push completed (repository :path))
      (if (= "/repo/1" (repository :path))
        (error "planned failure")
        :succeeded))))

(assert (= 2 (failed :succeeded)) "successful work continues after an error")
(assert (= 1 (failed :failed)) "an operation error counts as a failure")
(assert (= 3 (length completed)) "an error does not stop later work")

(assert-error "a misplaced live flag is rejected instead of hanging"
              (parallel/make-progress 3 outcomes false))
(assert-error "a fractional job count is rejected"
              (parallel/make-progress 3 outcomes 1.5))

# Clamping the count to the repository total must not launder a bad value,
# so these reject regardless of how many repositories there are.
(each count [0 -2 1.5 false]
  (each total [1 5]
    (assert-error (string "run-repositories rejects " count
                          " with " total " repositories")
                  (parallel/run-repositories
                    (slice repositories 0 total) outcomes
                    (fn [repository report] :succeeded)
                    count))))

(def progress (parallel/make-progress 3 outcomes 1 false))
(put (progress :active) 0 "/a/long/common/path/first")
(put (progress :counts) :succeeded 1)
(put (progress :counts) :failed 1)
(def lines (parallel/progress-lines progress 32))

(assert (= 2 (length lines)) "progress has one active row and one tally")
(assert (string/has-prefix? "⠋ " (lines 0)) "an active row starts with a spinner")
(assert (= "2/3  1 succeeded  0 skipped  1 f"
           (lines 1))
        "the tally is truncated to the terminal width")
(assert (= "…/common/path/first"
           (parallel/fit-path "/a/long/common/path/first" 20))
        "long paths keep their distinguishing tail")

(end-suite)
