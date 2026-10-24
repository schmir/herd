# Tests for narrowing repository lists with named filters.
(use spork/test)
(import spork/path)
(import spork/json)
(import spork/sh)
(import ../src/config)
(import ../src/named-filters)
(import ../src/process)

(start-suite "named-filters")

(var fixture-count 0)

(defn- fixture
  "A fresh empty directory for one test, named so parallel runs cannot collide."
  []
  (++ fixture-count)
  (def dir (path/join (os/getenv "TMPDIR" "/tmp")
                      (string "herd-filter-test-" (os/getpid) "-" fixture-count)))
  (sh/rm dir)
  (sh/create-dirs dir)
  (os/realpath dir))

(defmacro- with-fixture
  ``Run `body` with `dir` bound to a fresh empty directory, removed however
  the body ends. A failing assertion carries on to the removal by itself; an
  error does not, and would otherwise leave the directory behind.``
  [dir & body]
  ~(let [,dir (fixture)]
     (defer (sh/rm ,dir)
       ,;body)))

(defn- stub-filter
  ``Put a stand-in for the filter program on PATH and return its directory.
  The stub answers with `body` whatever it is handed, so these tests exercise
  herd's side of the exchange; JMESPath itself is the real program's business.
  It is called as `jp -- EXPRESSION` with the list on standard input, so the
  body reads the list from stdin and finds the expression at $2.``
  [dir body &opt status]
  (default status 0)
  (def bin (path/join dir "bin"))
  (sh/create-dirs bin)
  (def script (path/join bin named-filters/filter-executable))
  (spit script (string "#!/bin/sh\n" body "\nexit " status "\n"))
  (os/chmod script 8r755)
  bin)

(defmacro- with-stub
  ``Run `body` with `bin` ahead of the usual PATH, so the stub stands in for
  the filter program while the stub itself can still reach its own tools.``
  [bin & body]
  (with-syms [$previous $bin]
    ~(let [,$previous (os/getenv "PATH")
           ,$bin ,bin]
       (defer (os/setenv "PATH" ,$previous)
         (os/setenv "PATH" (string ,$bin ":" ,$previous))
         ,;body))))

(defmacro- without-filter-program
  ``Run `body` with a PATH that holds no filter program at all, using `dir` to
  hold the empty directory that stands in for one.``
  [dir & body]
  (with-syms [$previous $empty]
    ~(let [,$previous (os/getenv "PATH")
           ,$empty (path/join ,dir "empty")]
       (sh/create-dirs ,$empty)
       (defer (os/setenv "PATH" ,$previous)
         (os/setenv "PATH" ,$empty)
         ,;body))))

(defn- error-message
  "Return the error a thunk raises as a string, or nil when it raises none."
  [thunk]
  (try (do (thunk) nil) ([err] (string err))))

# Filters take and answer with JSON text rather than Janet values, so that an
# expression sees the file itself. These fixtures are text for the same reason.
(def entries
  (string `[{"path": "a", "ssh_url": "git@example.com:a.git"},`
          ` {"path": "b", "ssh_url": "git@example.com:b.git"}]`))

(defn- large-entries
  "A list far too large to sit in a pipe buffer."
  []
  (string "["
          (string/join
            (seq [index :range [0 20000]]
              (string/format `{"path": "repo-%d", "ssh_url": "u"}` index))
            ",")
          "]"))

(defn- paths
  "The paths in a filter's answer, so assertions read as plain lists."
  [answer]
  (map (fn [repository] (repository :path)) (json/decode answer true)))

# --- validate-registry ----------------------------------------------------

(defmacro- assert-error
  "Assert that `form` raises."
  [message form]
  ~(assert (error-message (fn [] ,form)) ,message))

(defmacro- assert-no-error
  "Assert that `form` raises nothing."
  [message form]
  ~(assert (nil? (error-message (fn [] ,form))) ,message))

(assert-error "the filter registry must be a dictionary"
              (named-filters/validate-registry []))
(assert-error "a filter needs an expression"
              (named-filters/validate-registry {"active" 1}))
(assert-error "a filter expression must not be empty"
              (named-filters/validate-registry {"active" ""}))
(assert-no-error "a filter names an expression"
                 (named-filters/validate-registry {"active" "[?schedules]"}))
(assert-no-error "a filter can say it is JMESPath or a shell command"
                 (named-filters/validate-registry {"a" {:jp "[?a]"} "b" {:sh "true"}}))
(assert-error "a filter dictionary needs :jp or :sh"
              (named-filters/validate-registry {"a" {}}))
(assert-error "a filter dictionary cannot be both"
              (named-filters/validate-registry {"a" {:jp "[?a]" :sh "true"}}))
(assert-error "a filter dictionary rejects other keys"
              (named-filters/validate-registry {"a" {:sh "true" :other 1}}))
(assert-error "a shell filter must not be empty"
              (named-filters/validate-registry {"a" {:sh ""}}))
(assert-error "a JMESPath filter must be a string"
              (named-filters/validate-registry {"a" {:jp 1}}))


# --- the kinds a registry tells apart ---------------------------------------

(def kinds-registry
  (named-filters/validate-registry
    {"a" "[?a]" "b" {:jp "[?b]"} "c" {:sh "true"}}))

(assert (and (named-filters/list-filter? kinds-registry "a")
             (named-filters/list-filter? kinds-registry "b"))
        "a string and a :jp entry are list filters")
(assert (not (named-filters/list-filter? kinds-registry "c"))
        "a :sh entry is not a list filter")
(assert (not (named-filters/list-filter? kinds-registry "absent"))
        "a name the registry lacks is not one either")
(assert (= "true" (named-filters/checkout-filter-command kinds-registry "c"))
        "a :sh entry stands for its command")
(assert (nil? (named-filters/checkout-filter-command kinds-registry "a"))
        "a list filter stands for no command")
(assert (nil? (named-filters/checkout-filter-command kinds-registry "absent"))
        "nor does a name the registry lacks")
(assert (deep= @["a" "b" "c"] (named-filters/filter-names kinds-registry))
        "the names come sorted, whatever the kind")
(assert (deep= {"a" "[?a]" "b" "[?b]" "c" "true"}
               (named-filters/descriptions kinds-registry))
        "each name is described by its expression or command")
(assert (empty? (named-filters/filter-names {})) "an empty registry has no names")

# --- check-names ----------------------------------------------------------

(assert-no-error "list filters may be named by a row"
                 (named-filters/require-list-filters kinds-registry ["a" "b"] ":defaults"))
(assert-no-error "a row may name none"
                 (named-filters/require-list-filters kinds-registry [] ":defaults"))
(let [message (error-message
                (fn [] (named-filters/require-list-filters kinds-registry ["c"] ":defaults")))]
  (assert (and message (string/find `names the command filter "c"` message)
               (string/find "only the command line" message))
          "a row cannot name a checkout filter, which runs in a checkout")
  (assert (string/has-prefix? ":defaults " message) "and the row is named first"))
(let [message (error-message
                (fn [] (named-filters/require-list-filters kinds-registry ["a" "typo"]
                                                           ":checkouts row for \"w.json\"")))]
  (assert (and message (string/find `names an unknown filter "typo"` message))
          "an unknown name is named, not the whole row"))

# --- narrow ---------------------------------------------------------------

(def narrow-registry
  (named-filters/validate-registry {"row" "[?row]" "cli" {:jp "[?cli]"} "c" {:sh "true"}}))

(with-fixture dir
  (without-filter-program dir
                          (assert (= entries (named-filters/narrow narrow-registry entries [] []))
                                  "naming no filter needs no filter program")))

(with-fixture dir
  (def log (path/join dir "expressions"))
  (with-stub (stub-filter dir (string `printf '%s\n' "$2" >> ` log "\necho '[]'"))
    (named-filters/narrow narrow-registry entries ["row"] ["cli"])
    (assert (deep= @["[?row]" "[?cli]"]
                   (string/split "\n" (string/trimr (slurp log))))
            "a row's filters narrow first, then those named with -f")))

(with-fixture dir
  (with-stub (stub-filter dir "echo boom >&2" 1)
    (def own (error-message
               (fn [] (named-filters/narrow narrow-registry entries ["row"] []))))
    (assert (and (string/find `filter "row" failed` own)
                 (not (string/find "applied to every configured list" own)))
            "a row's own filter fails without the hint")
    (def named (error-message
                 (fn [] (named-filters/narrow narrow-registry entries [] ["cli"]))))
    (assert (and (string/find `filter "cli" failed` named)
                 (string/find "applied to every configured list" named))
            "a filter named with -f fails with the hint")))

# --- apply-filter ---------------------------------------------------------

(with-fixture dir
  (with-stub (stub-filter dir `echo '[{"path":"a","ssh_url":"git@example.com:a.git"}]'`)
    (def kept (named-filters/apply-filter entries "keep-a" "[?path=='a']"))
    (assert (string? kept) "a filter answers with the JSON it wrote")
    (assert (deep= (paths kept) @["a"])
            "a filter narrows the list to what it selected")))

# The list arrives on standard input, holding what was read from disk.
(with-fixture dir
  (def copy (path/join dir "handed-over"))
  (with-stub (stub-filter dir (string `cat > ` copy "\necho '[]'"))
    (named-filters/apply-filter entries "any" "@")
    # Byte for byte, not merely the same values once decoded: decoding and
    # re-encoding rounds numbers to what a double can hold and reorders
    # every object key, behind the expression's back.
    (assert (= entries (string (slurp copy)))
            "a filter is handed the list exactly as it stands")))

(with-fixture dir
  (with-stub (stub-filter dir "echo null")
    # An expression that is not a filter succeeds and answers null, which
    # would otherwise select nothing without saying why.
    (assert (string/find "did not select an array of repositories"
                         (error-message (fn [] (named-filters/apply-filter entries "bare" "path"))))
            "null output is refused rather than read as an empty selection")))

(with-fixture dir
  (with-stub (stub-filter dir "echo 'SyntaxError: Incomplete expression' >&2" 1)
    (def message (error-message (fn [] (named-filters/apply-filter entries "broken" "[?"))))
    (assert (string/find `filter "broken" failed` message)
            "a failing filter is named in the error")
    (assert (string/find "SyntaxError" message)
            "a failing filter carries what it reported")))

(with-fixture dir
  (with-stub (stub-filter dir "echo 'not json'")
    (assert (string/find "produced unreadable output"
                         (error-message (fn [] (named-filters/apply-filter entries "odd" "@"))))
            "output that is not JSON is refused with the filter named")))

# A filter that rejects its expression answers at once without reading the
# list. A large list must not turn that into a broken pipe that kills herd
# before it can report what the filter said.
(with-fixture dir
  (with-stub (stub-filter dir "echo 'SyntaxError: Incomplete expression' >&2" 1)
    (assert (string/find "SyntaxError"
                         (error-message
                           (fn [] (named-filters/apply-filter (large-entries) "broken" "[?"))))
            "a filter that never reads a large list still reports why")))

(with-fixture dir
  (with-stub (stub-filter dir "echo '[]'")
    (assert (empty? (paths (named-filters/apply-filter (large-entries) "big" "[?false]")))
            "a list too large for a pipe buffer is filtered all the same")))

(with-fixture dir
  (without-filter-program dir
                          (assert (string/find (string "needs " named-filters/filter-executable " on PATH")
                                               (error-message (fn [] (named-filters/apply-filter entries "any" "@"))))
                                  "a missing filter program is reported against the filter")))

# The list is held in a file with no name, handed over as standard input.
# That it is a regular file and not a pipe is the whole point: a filter that
# answers without reading cannot then break a pipe herd is still writing to.
(with-fixture dir
  (def kind (path/join dir "kind"))
  (with-stub (stub-filter dir
                          (string `if [ -p /dev/stdin ]; then echo pipe > ` kind
                                  `; else echo file > ` kind "; fi\n"
                                  "echo '[]'"))
    (named-filters/apply-filter entries "any" "@")
    (assert (= "file" (string/trimr (slurp kind)))
            "the filter reads a regular file, never a pipe")))

# Nothing is left for another user on the machine to find. tmpfile(3) uses
# /tmp whatever TMPDIR says, so both are worth looking at. The shape looked
# for is the one every named revision of this wrote: herd-filter-<id>.json,
# which the fixture directories above deliberately do not match.
(with-fixture dir
  (with-stub (stub-filter dir "echo '[]'")
    (named-filters/apply-filter entries "any" "@")
    (named-filters/apply-filter (large-entries) "any" "@")
    (each place (distinct ["/tmp" (os/getenv "TMPDIR" "/tmp")])
      (assert (empty? (filter (fn [name] (and (string/has-prefix? "herd-filter-" name)
                                              (string/has-suffix? ".json" name)))
                              (os/dir place)))
              (string "filtering leaves no input file in " place)))))

# Values a decode/re-encode would quietly change on the way to the filter:
# an integer wider than a double, a fraction no double holds exactly, an
# exponent that overflows to infinity, and keys whose order is the file's
# rather than a hash table's.
(def awkward
  (string `[{"zebra": 1, "alpha": 2, "id": 12345678901234567890,`
          ` "frac": 0.1, "huge": 1e400, "path": "a", "ssh_url": "u"}]`))

(with-fixture dir
  (def copy (path/join dir "handed-over"))
  (with-stub (stub-filter dir (string `cat > ` copy "\necho '[]'"))
    (named-filters/apply-filter awkward "any" "@")
    (assert (= awkward (string (slurp copy)))
            "numbers and key order reach the filter untouched")))

# --- filter-entries -------------------------------------------------------

(with-fixture dir
  (without-filter-program dir
                          # Naming no filter must not reach for the program at all, so an
                          # unfiltered herd needs nothing installed.
                          (assert (= entries (named-filters/apply-filters entries [] {}))
                                  "naming no filter hands the source back untouched")))

(with-fixture dir
  (def log (path/join dir "expressions"))
  (with-stub (stub-filter dir (string `printf '%s\n' "$2" >> ` log "\necho '[]'"))
    (named-filters/apply-filters entries ["first" "second"]
                                 {"first" "[?a]" "second" "[?b]"})
    (assert (deep= @["[?a]" "[?b]"]
                   (string/split "\n" (string/trimr (slurp log))))
            "each named filter runs in turn, in the order named")))

# Filters pipe into one another: what one kept is all the next one sees. The
# stub always answers with a single entry, so the second filter has to be
# handed a shorter list than the first was.
(with-fixture dir
  (def sizes (path/join dir "sizes"))
  (with-stub (stub-filter dir
                          (string `wc -c >> ` sizes "\n"
                                  `echo '[{"path":"a","ssh_url":"u"}]'`))
    (def kept (named-filters/apply-filters entries ["first" "second"]
                                           {"first" "@" "second" "@"}))
    (def logged (map scan-number
                     (string/split "\n" (string/trimr (slurp sizes)))))
    (assert (= 2 (length logged)) "both filters ran")
    (assert (< (logged 1) (logged 0))
            "each filter narrows what the next one is given")
    (assert (deep= @["a"] (paths kept))
            "the narrowed list is what comes back")))

# A filter a row named was aimed at that row's own file, so a failure there
# needs no explaining. One named with -f met a list nobody paired it with,
# which is the surprise worth a word.
(with-fixture dir
  (with-stub (stub-filter dir "echo 'Invalid type for: <nil>' >&2" 1)
    (def named (error-message
                 (fn [] (named-filters/apply-filter entries "cli" "@" named-filters/command-filter-hint))))
    (assert (string/find "applied to every configured list" named)
            "a filter named on the command line explains itself")
    (assert (string/find "Invalid type" named)
            "and still carries what the filter reported")
    (def own (error-message (fn [] (named-filters/apply-filter entries "row" "@"))))
    (assert (string/find "Invalid type" own)
            "a row's own filter reports what the filter said")
    (assert (not (string/find "applied to every configured list" own))
            "and is not lectured about where it was named")))

# The hint reaches whichever filter in a chain fails, not just the first.
(with-fixture dir
  (with-stub (stub-filter dir
                          (string `case "$2" in ok) echo '[]';; *) echo boom >&2; exit 1;; esac`))
    (def message (error-message
                   (fn [] (named-filters/apply-filters entries ["first" "second"]
                                                       {"first" "ok" "second" "no"}
                                                       named-filters/command-filter-hint))))
    (assert (string/find `filter "second" failed` message)
            "the failing filter in the chain is the one named")
    (assert (string/find "applied to every configured list" message)
            "and the hint travels the whole chain")))

# --- read-repository-list ----------------------------------------------------------

# This stub answers with the expression it was handed, so a filter here is
# simply the list it yields. What is being tested is which entries reach
# which anchor, not JMESPath.
(defn- answering-stub
  "A stub whose answer is the expression itself."
  [dir]
  (stub-filter dir `printf '%s' "$2"`))

# A generated list may carry more than herd needs, and more than herd would
# accept: the third entry here is not a repository at all.
(def listing
  (string `[{"path": "a", "ssh_url": "git@example.com:a.git"},`
          ` {"path": "b", "ssh_url": "git@example.com:b.git"},`
          ` {"note": "not a repository at all"}]`))

(def answers
  {"first" `[{"path": "a", "ssh_url": "git@example.com:a.git"}]`
   "second" `[{"path": "b", "ssh_url": "git@example.com:b.git"}]`
   "none" "[]"})

(with-fixture dir
  (def config (path/join dir "repos.json"))
  (def src (path/join dir "src"))
  (def vendor (path/join dir "vendor"))
  (spit config listing)
  (with-stub (answering-stub dir)
    (assert (deep= @[(path/join src "a")]
                   (map (fn [repository] (repository :path))
                        (config/read-repository-list config nil
                                                     @[{:anchor src :filter ["first"]}]
                                                     answers)))
            "a row's filter narrows what its file contributes")

    (assert (deep= @[(path/join src "a")]
                   (map (fn [repository] (repository :path))
                        (config/read-repository-list
                          config nil
                          @[{:anchor src
                             :filter ["prefixed"]
                             :strip-components 1}]
                          {"prefixed"
                           `[{"path": "org/a", "ssh_url": "u"}]`})))
            "a row strips paths produced by its filter")

    # Reading the same file unfiltered fails on the third entry, so only
    # what a filter kept can have been validated above.
    (assert (string/find "needs a string"
                         (error-message
                           (fn [] (config/read-repository-list config nil @[{:anchor src}] answers))))
            "an entry no filter removed still has to be a repository")

    (assert (deep= @[(path/join src "a") (path/join vendor "b")]
                   (map (fn [repository] (repository :path))
                        (config/read-repository-list config nil
                                                     @[{:anchor src :filter ["first"]}
                                                       {:anchor vendor :filter ["second"]}]
                                                     answers)))
            "two rows take different parts of one file")

    (assert (empty? (config/read-repository-list config nil
                                                 @[{:anchor src :filter ["first"]}]
                                                 answers
                                                 ["none"]))
            "a command-line filter narrows what the row already kept")))

# Which filter a name came from decides whether the failure explains itself,
# and read-repository-list is where that distinction is actually drawn.
(with-fixture dir
  (def config (path/join dir "repos.json"))
  (def src (path/join dir "src"))
  (def answers {"good" "ok" "bad" "no"})
  (spit config `[{"path": "a", "ssh_url": "git@example.com:a.git"}]`)
  # Only "ok" succeeds; anything else fails the way a field a list does not
  # carry fails.
  (with-stub (stub-filter dir
                          (string `case "$2" in ok) echo '[]';; *) echo boom >&2; exit 1;; esac`))
    (def from-command
      (error-message (fn [] (config/read-repository-list config nil @[{:anchor src}] answers ["bad"]))))
    (assert (string/find "applied to every configured list" from-command)
            "a filter named with -f explains why it reached this list")

    (def from-row
      (error-message
        (fn [] (config/read-repository-list config nil @[{:anchor src :filter ["bad"]}] answers))))
    (assert (string/find "boom" from-row)
            "a row's own filter still reports what the filter said")
    (assert (not (string/find "applied to every configured list" from-row))
            "but is not explained, having been aimed at this list")

    # A row's filters run before the command line's, so a row filter that
    # fails is reported even when a command-line filter is also named.
    (def both
      (error-message
        (fn [] (config/read-repository-list config nil @[{:anchor src :filter ["bad"]}]
                                            answers ["good"]))))
    (assert (not (string/find "applied to every configured list" both))
            "the row's filter fails first, and speaks for itself")))

# Rows sharing a filter chain share the work, which means the chain has to
# identify itself exactly. Joining names into one string cannot: a name is an
# arbitrary string, so any separator can appear inside one and two different
# chains can spell the same key. The second row would then be handed the
# first row's repositories and resolve them under its own anchor.
(with-fixture dir
  (def config (path/join dir "repos.json"))
  (def one (path/join dir "one"))
  (def two (path/join dir "two"))
  (def answers {"a\0b" `[{"path": "x", "ssh_url": "git@example.com:x.git"}]`
                "a" `[{"path": "y", "ssh_url": "git@example.com:y.git"}]`
                "b" `[{"path": "y", "ssh_url": "git@example.com:y.git"}]`})
  (spit config `[{"path": "x", "ssh_url": "git@example.com:x.git"}]`)
  (with-stub (answering-stub dir)
    (def repositories
      (config/read-repository-list config nil
                                   @[{:anchor one :filter ["a\0b"]}
                                     {:anchor two :filter ["a" "b"]}]
                                   answers))
    (assert (deep= @[(path/join one "x") (path/join two "y")]
                   (map (fn [repository] (repository :path)) repositories))
            "chains that merely spell alike are kept apart")))

# Keying on the chain still has to share the work it was there to share: two
# rows filtering alike differ only in where they land, so the filter runs once.
(with-fixture dir
  (def config (path/join dir "repos.json"))
  (def runs (path/join dir "runs"))
  (def one (path/join dir "one"))
  (def two (path/join dir "two"))
  (def three (path/join dir "three"))
  (spit config `[{"path": "r", "ssh_url": "git@example.com:r.git"}]`)
  (with-stub (stub-filter dir
                          (string `printf 'x' >> ` runs "\n"
                                  `printf '%s' "$2"`))
    (def answer `[{"path": "r", "ssh_url": "git@example.com:r.git"}]`)
    (def repositories
      (config/read-repository-list config nil
                                   @[{:anchor one :filter ["same"]}
                                     {:anchor two :filter ["same"]}
                                     {:anchor three :filter ["other"]}]
                                   {"same" answer "other" answer}))
    (assert (= 3 (length repositories)) "every row still contributes its checkout")
    (assert (= 2 (length (slurp runs)))
            "the shared chain is filtered once, the distinct one again")))

# Order matters, which is why the documentation says pipeline and not
# intersection. Two filter expressions commute, so naming them either way
# round selects the same repositories. A slice does not: taking the first
# entry of the active ones is not taking the active ones of the first entry.
(when (process/find-executable named-filters/filter-executable)
  (let [listing
        (string `[{"path": "one", "ssh_url": "u", "active": false, "tier": 1},`
                ` {"path": "two", "ssh_url": "u", "active": true, "tier": 1}]`)
        filters {"active" "[?active]" "tier" "[?tier == `1`]" "first" "[0:1]"}
        selected (fn [& names] (paths (named-filters/apply-filters listing names filters)))]
    (assert (deep= (selected "active" "tier") (selected "tier" "active"))
            "filter expressions commute, so naming them either way round agrees")
    (assert (deep= @["two"] (selected "active" "first"))
            "the first of the active repositories is the active one")
    (assert (empty? (selected "first" "active"))
            "while the first repository of the list is not active at all")))

# --- against the real filter program --------------------------------------

# Guarded, so the suite does not require the program to be installed.
(when (process/find-executable named-filters/filter-executable)
  (with-fixture dir
    (def config (path/join dir "repos.json"))
    (def src (path/join dir "src"))
    (spit config
          (string `[{"path": "a", "ssh_url": "git@example.com:a.git",`
                  ` "schedules": [{"name": "nightly-1"}]},`
                  ` {"path": "b", "ssh_url": "git@example.com:b.git",`
                  ` "schedules": []}]`))
    (def filters
      {"active" "[?schedules[?starts_with(name, 'nightly-')]]"
       "none" "[?path=='absent']"})
    (assert (deep= @[(path/join src "a")]
                   (map (fn [repository] (repository :path))
                        (config/read-repository-list config nil
                                                     @[{:anchor src :filter ["active"]}]
                                                     filters)))
            "a real JMESPath expression selects by a field herd knows nothing of")
    (assert (empty? (config/read-repository-list config nil @[{:anchor src}] filters ["none"]))
            "and an expression matching nothing selects nothing")))

(end-suite)
