# Reading the entries a repository list holds.

(import spork/json)
(import ./checkout)

(defn parse-config
  "Parse JSON source into Janet data."
  [source]
  (json/decode source true))

(defn validate-config
  "Return rows unchanged, or raise a descriptive error describing their shape."
  [rows]
  (unless (indexed? rows)
    (error "expected a JSON array of repository objects"))
  (for index 0 (length rows)
    (def entry (rows index))
    (unless (dictionary? entry)
      (error (string "entry " index " is not a JSON object")))
    (each key [:path :ssh_url]
      (unless (string? (entry key))
        (error (string "entry " index " needs a string \"" key "\""))))
    (checkout/validate-checkout-options entry (string "entry " index) `"vcs"`))
  rows)
