# Reading the entries a repository list holds.

(import spork/json)
(import ./checkout)

(defn parse-config
  "Parse JSON source into Janet data."
  [source]
  (json/decode source true))

(defn validate-config
  "Return config unchanged, or raise a descriptive error describing its shape."
  [config]
  (unless (indexed? config)
    (error "expected a JSON array of repository objects"))
  (for index 0 (length config)
    (def entry (config index))
    (unless (dictionary? entry)
      (error (string "entry " index " is not a JSON object")))
    (each key [:path :ssh_url]
      (unless (string? (entry key))
        (error (string "entry " index " needs a string \"" key "\""))))
    (checkout/validate-checkout-options entry (string "entry " index) `"vcs"`))
  config)
