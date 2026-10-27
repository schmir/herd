# Tests for picking a stable share of the repositories.
(use spork/test)
(import ../src/sample)

(start-suite "sample")

(defn- repository
  "A repository entry cloned from `url`, placed at `path`."
  [url &opt path]
  {:path (or path "/unused") :clone-url url})

(defn test-crc32-matches-zlib
  "The checksum is the CRC-32 zlib computes, so any tool can say what is picked."
  []
  (assert (= 0xCBF43926 (sample/crc32 "123456789")) "the CRC-32 check value")
  (assert (= 0 (sample/crc32 "")) "the CRC-32 of nothing")
  (assert (= 2946902113 (sample/crc32 "https://example.com/zeta.git"))))

(defn test-parse-reads-a-percentage-or-a-range
  "A single percentage samples from 0, and LOW:HIGH from LOW, as a slice does."
  []
  (assert (deep= [0 10] (sample/parse "10")))
  (assert (deep= [0 100] (sample/parse "100")))
  (assert (deep= [10 20] (sample/parse "10:20")))
  (assert (deep= [0 10] (sample/parse ":10")) "a missing LOW is 0")
  (assert (deep= [90 100] (sample/parse "90:")) "a missing HIGH is 100")
  (assert (deep= [0 100] (sample/parse "0:100")))
  (assert (deep= [0 100] (sample/parse ":")) "a range without ends is everything")
  (each text ["0" "0.5" "0.100" "10.20" "10..20" "1e1" "0x10" "+5" "-5" "101"
              "20:10" "10:10" "1:2:3" "10:101" "many" ""]
    (assert-error (string (describe text) " is not a sample")
                  (sample/parse text))))

(defn test-format-writes-what-parse-reads
  "A sample is written as briefly as parse reads it back."
  []
  (assert (= "10" (sample/format [0 10])))
  (assert (= "10:20" (sample/format [10 20])))
  (assert (= "90:" (sample/format [90 100])))
  (each text ["10" "10:20" "90:" "100"]
    (assert (= text (sample/format (sample/parse text))))))

(def urls (map |(string "https://example.com/repo-" $ ".git") (range 1000)))
(def repositories (map repository urls))

(defn test-a-sample-keeps-about-its-share
  "A sample keeps about the share it names, in the order given."
  []
  (def kept (sample/keep-sample repositories [0 25]))
  (assert (< 200 (length kept) 300) "about a quarter is kept")
  (assert (deep= kept (filter (fn [repository] (index-of repository kept))
                              repositories))
          "the order is kept")
  (assert (< 200 (length (sample/keep-sample repositories [50 75])) 300)
          "a range keeps about its width")
  (assert (= 1000 (length (sample/keep-sample repositories [0 100])))
          "100 percent keeps every repository"))

(defn test-samples-nest
  "Whatever a smaller sample picks, a larger one picks too."
  []
  (def small (sample/keep-sample repositories [0 10]))
  (def large (sample/keep-sample repositories [0 20]))
  (assert (< (length small) (length large)))
  (assert (all (fn [repository] (index-of repository large)) small)
          "the 10 percent sample is part of the 20 percent one"))

(defn test-adjacent-ranges-split-a-sample
  "Ranges that meet share no repository and together make up the range they span."
  []
  (def lower (sample/keep-sample repositories [0 10]))
  (def upper (sample/keep-sample repositories [10 20]))
  (assert (not (some (fn [repository] (index-of repository upper)) lower))
          "0..10 and 10..20 pick different repositories")
  (assert (= (length (sample/keep-sample repositories [0 20]))
             (+ (length lower) (length upper)))
          "together they pick what 0..20 does"))

(defn test-the-url-decides
  "The clone URL decides, wherever the repository is placed."
  []
  (each url (take 50 urls)
    (assert (= (sample/sampled? (repository url "/one/place") [0 30])
               (sample/sampled? (repository url "/another/place") [0 30]))
            (string url " is picked the same under every path"))))

(test-crc32-matches-zlib)
(test-parse-reads-a-percentage-or-a-range)
(test-format-writes-what-parse-reads)
(test-a-sample-keeps-about-its-share)
(test-samples-nest)
(test-adjacent-ranges-split-a-sample)
(test-the-url-decides)

(end-suite)
