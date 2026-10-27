# Picking a stable share of the repositories by a checksum of their clone URL.

(import spork/crc)

(def- crc-range
  "The number of values a CRC-32 can take."
  4294967296)

(defn crc32
  ``The CRC-32 of `text`, as zlib computes it. The variant spork/crc returns
  is an abstract value the executable's image cannot marshal, so it is made
  on each call rather than once at load time; that only fills a small table.``
  [text]
  ((crc/named-variant :crc32) text))

(defn- bound
  ``The percentage `text` writes, `missing` when it is empty, or nil when it
  is anything but digits. Only whole numbers are read, so a slip such as
  0.100 for 0:100 is a mistake rather than a sample of 0.1 percent.``
  [text missing]
  (cond
    (empty? text) missing
    (peg/match ~(* :d+ -1) text) (scan-number text)))

(defn parse
  ``Return the sample `text` names as `[low high]` percentages, or raise. A
  single PERCENT is the first PERCENT percent, the same as 0:PERCENT.
  LOW:HIGH is the half-open range from LOW up to HIGH, as a slice is, so
  0:10 and 10:20 pick different repositories. A missing LOW is 0 and a
  missing HIGH is 100.``
  [text]
  (def parts (string/split ":" text))
  (def [low high]
    (case (length parts)
      1 [0 (bound (parts 0) nil)]
      2 [(bound (parts 0) 0) (bound (parts 1) 100)]
      [nil nil]))
  (unless (and low high (<= 0 low) (< low high) (<= high 100))
    (error (string "expected a whole percentage from 1 to 100, "
                   "or LOW:HIGH with 0 <= LOW < HIGH <= 100")))
  [low high])

(defn format
  "Write the sample `[low high]` the way parse reads it, as briefly as it can be."
  [[low high]]
  (cond
    (zero? low) (string high)
    (= 100 high) (string low ":")
    (string low ":" high)))

(defn sampled?
  ``Whether the repository is in the sample `[low high]`: whether the CRC-32
  of its clone URL lies from `low` percent up to, but not including, `high`
  percent of the values a CRC-32 can take. The URL is the same wherever the
  repository is placed, so every machine picks the same repositories, a
  sample from 0 is part of every larger one from 0, and adjacent ranges do
  not overlap.``
  [repository [low high]]
  (def checksum (crc32 (repository :clone-url)))
  (and (<= (* low 0.01 crc-range) checksum)
       (< checksum (* high 0.01 crc-range))))

(defn keep-sample
  "Keep the `repositories` in the sample `[low high]`, in their order."
  [repositories sample]
  (filter (fn [repository] (sampled? repository sample)) repositories))
