# Replacing the running herd with the latest release, or one named.
#
# Janet speaks neither HTTPS nor SHA-256, so curl downloads, tar unpacks and
# sha256sum, shasum or sha256 checks, as herd runs git and jj.

(import spork/json)
(import spork/path)
(import spork/sh)
(import ./process)

(def default-releases-url
  "Where GitHub describes herd's releases, unless HERD_RELEASES_URL names another."
  "https://api.github.com/repos/schmir/herd/releases")

(defn releases-url
  "The URL herd's releases are described beneath, as HERD_RELEASES_URL may override it."
  []
  (def named (os/getenv "HERD_RELEASES_URL"))
  (string/trimr (if (or (nil? named) (empty? named)) default-releases-url named) "/"))

(defn release-tag
  ``The tag of the release `version` names: the tag itself, or a version
  number without the v the tags start with. Raise when it cannot be a tag, so
  nothing but a tag ever ends up in a URL.``
  [version]
  (unless (peg/match ~(* (some (+ :w (set "._-"))) -1) version)
    (error (string (describe version) " is not a release version")))
  (if (peg/match ~(* :d) version) (string "v" version) version))

(defn release-url
  ``The URL of the description of the release `tag`, or of the latest release
  when `tag` is nil, beneath `base`, as the GitHub releases API lays them out.``
  [base tag]
  (if tag
    (string base "/tags/" tag)
    (string base "/latest")))

(defn platform
  ``The release platform name for `os` and `arch`, as os/which and os/arch
  name them, or nil when no release is built for it. The names are those of
  the dist recipe in the justfile.``
  [os arch]
  (case [os arch]
    [:linux :x64] "linux-x86_64"
    [:linux :aarch64] "linux-aarch64"
    [:linux :arm64] "linux-aarch64"
    [:macos :aarch64] "macos-arm64"
    [:macos :arm64] "macos-arm64"
    [:macos :x64] "macos-x86_64"
    [:openbsd :x64] "openbsd-amd64"
    [:openbsd :aarch64] "openbsd-arm64"
    [:openbsd :arm64] "openbsd-arm64"
    [:freebsd :x64] "freebsd-amd64"
    [:freebsd :aarch64] "freebsd-arm64"
    [:freebsd :arm64] "freebsd-arm64"))

(defn archive-name
  "The name of the archive release `tag` ships for `platform`."
  [tag platform]
  (string "herd-" tag "-" platform ".tar.gz"))

(defn checksums-name
  "The name of the checksum file of release `tag`."
  [tag]
  (string "herd-" tag "-SHA256SUMS"))

(defn release-assets
  ``The tag and the download URLs by asset name that `text`, a GitHub release
  description in JSON, holds, as {:tag :assets}. Taking the URLs from the
  description rather than building them lets a mirror lay them out its own way.``
  [text]
  (def release
    (try (json/decode text)
      ([_] (error "the release description is not JSON"))))
  (def tag (when (dictionary? release) (get release "tag_name")))
  (unless (string? tag)
    (error "the release description names no tag"))
  {:tag tag
   :assets (tabseq [asset :in (get release "assets" [])
                    :when (and (dictionary? asset)
                               (string? (get asset "name")))]
             (get asset "name") (get asset "browser_download_url"))})

(defn expected-checksum
  ``The SHA-256 that `sums`, the text of a sha256sum file, gives for the file
  `name`, or nil when it gives none.``
  [sums name]
  (some (fn [line]
          (def [hash file] (string/split " " (string/trim line) 0 2))
          # sha256sum marks a file it read in binary mode with a *.
          (when (and file (= name (string/triml file " *")))
            hash))
        (string/split "\n" sums)))

(defn- run
  ``Run `args` and return its stdout, or raise `what` failed with its stderr.
  `input`, if given, is what the program reads on standard input.``
  [what args &opt input]
  (def result
    (if input
      (let [[reader writer] (os/pipe)]
        # Written before the program starts, which a pipe buffer holds as
        # long as the input is a few lines.
        (:write writer input)
        (:close writer)
        (defer (:close reader)
          (process/capture args nil {:in reader})))
      (process/capture args)))
  (unless (zero? (result :status))
    (error (string what " failed: " (string/trim (result :err)))))
  (result :out))

(defn- program
  "The path of the program `name` on PATH, or raise."
  [name]
  (or (process/find-executable name)
      (error (string name " was not found on PATH"))))

# HTTPS, and file for a release laid out on disk; --proto-redir keeps a
# redirect from leaving them.
(def- curl-flags ["-fsSL" "--proto" "=https,file" "--proto-redir" "=https,file"])

(defn github-token
  "The GitHub token GH_TOKEN or else GITHUB_TOKEN holds, as gh reads them, or nil."
  []
  (some (fn [name]
          (def token (os/getenv name))
          (unless (or (nil? token) (empty? token)) token))
        ["GH_TOKEN" "GITHUB_TOKEN"]))

(defn authorization
  ``The curl configuration that sends `token` with a request for `url`, or nil
  when there is no token or the URL is not GitHub's API. A mirror never sees
  the token, and neither do the downloads, which GitHub does not count
  against the API's rate limit.``
  [url token]
  (when (and token (string/has-prefix? "https://api.github.com/" url))
    (def quoted (string/replace-all "\"" "\\\""
                                    (string/replace-all "\\" "\\\\" token)))
    (string "header = \"Authorization: Bearer " quoted "\"\n")))

(defn fetch
  ``The body at `url`, or raise when it cannot be downloaded. A GitHub token
  goes to curl on its standard input, as authorization says, rather than on
  its command line, where any user of the machine could read it.``
  [url]
  (def config (authorization url (github-token)))
  (string (run (string "downloading " url)
               [(program "curl") ;curl-flags ;(if config ["-K" "-"] []) url]
               config)))

(defn- curl-diagnostic
  ``The last message curl printed in `text`, its standard error, which may
  begin with a progress bar, or an empty string when there is none.``
  [text]
  (def starts (peg/match ~(any (+ (* ($) "curl:") 1)) text))
  (if (empty? starts)
    ""
    (string/trim (string/slice text (last starts)))))

(defn download
  ``Write what is at `url` to `dest`, or raise when it cannot be downloaded.
  curl's standard error is kept to put its message in the error, and is
  passed on to ours as it comes when `progress` is true, so that a progress
  bar shows while a file arrives, which is for files large enough to need one.``
  [url dest &opt progress]
  (def args [(program "curl") "-fL" (if progress "--progress-bar" "-sS")
             "--proto" "=https,file" "--proto-redir" "=https,file"
             "-o" dest url])
  (def diagnostics @"")
  (def status
    (with [process (os/spawn args :p {:in :pipe :out :pipe :err :pipe})]
      (:close (process :in))
      (ev/gather
        (:read (process :out) :all @"")
        (while (def chunk (:read (process :err) 4096))
          (buffer/push diagnostics chunk)
          (when progress
            (file/write stderr chunk)
            (file/flush stderr)))
        (:wait process))
      (process :return-code)))
  (unless (zero? status)
    (def said (curl-diagnostic diagnostics))
    (error (string "downloading " url " failed"
                   (if (empty? said) "" (string ": " said))))))

(defn failure-hint
  ``What to add to the error `err` of a request for `url`, sent with `token`
  or without one, when GitHub's API answered it with a status a token
  explains, or an empty string.``
  [err url token]
  (defn status? [& codes]
    (peg/find ~(* "error: " (+ ,;codes)) (string err)))
  (cond
    (not (string/has-prefix? "https://api.github.com/" url)) ""
    (and token (status? "401"))
    "; GitHub rejected the token in GH_TOKEN or GITHUB_TOKEN"
    # Without a token, GitHub allows 60 API requests an hour from one
    # address, which a shared one can use up for everyone behind it.
    (and (nil? token) (status? "403" "429"))
    "; GitHub may be limiting requests, set GH_TOKEN or GITHUB_TOKEN to send a token"
    ""))

(defn sha256
  "The SHA-256 of `file` in hex, by sha256sum or, where there is none, shasum or (on OpenBSD) sha256."
  [file]
  (def args
    (if-let [sha256sum (process/find-executable "sha256sum")]
      [sha256sum file]
      (if-let [shasum (process/find-executable "shasum")]
        [shasum "-a" "256" file]
        (if-let [sha256 (process/find-executable "sha256")]
          [sha256 "-q" file]
          (error "neither sha256sum, shasum nor sha256 was found on PATH")))))
  (first (string/split " " (string/trim (run "checksumming" args)))))

(defn own-executable
  ``The file the program started as `argv0` runs from: a name with a slash in
  it is a path, and a bare name was found on PATH, as the shell finds it. Links
  are resolved, so the update replaces the file a link leads to, not the link.``
  [argv0]
  (def found
    (if (string/find "/" argv0)
      argv0
      (or (process/find-executable argv0)
          (error (string "cannot find " argv0 " on PATH")))))
  (os/realpath found))

(defn update-executable
  ``Replace the herd at `executable` with the release `version` names, or the
  latest release without one, unless it is `current-version` already. `report`
  is told what happened. Return :current or :updated, or raise a string saying
  what went wrong.``
  [current-version executable &opt version report]
  (default report print)
  (def requested (when version (release-tag version)))
  (def platform-name
    (or (platform (os/which) (os/arch))
        (error (string "there is no release binary for "
                       (os/which) "-" (os/arch)))))
  (def url (release-url (releases-url) requested))
  (eprint "Downloading " url)
  (def description
    (try (fetch url)
      ([err]
        (error (string (if requested
                         (string "cannot find release " requested ": " err)
                         err)
                       (failure-hint err url (github-token)))))))
  (def {:tag tag :assets assets} (release-assets description))
  (when (and requested (not= tag requested))
    (error (string "asked for release " requested ", but the description is of " tag)))
  (if (= tag current-version)
    (do
      (report "herd " tag (if requested " is already installed" " is already the latest release"))
      :current)
    (do
      (def archive (archive-name tag platform-name))
      (def sums (checksums-name tag))
      (each name [archive sums]
        (unless (string? (get assets name))
          (error (string "release " tag " has no " name))))
      # Staged beside the executable, so the rename that replaces it stays on
      # one file system.
      (def staging (path/join (path/dirname executable)
                              (string ".herd-update-" (os/getpid))))
      (sh/rm staging)
      (try
        (os/mkdir staging)
        ([err]
          (error (string "cannot write to " (path/dirname executable) ": " err))))
      (defer (sh/rm staging)
        (def archive-path (path/join staging archive))
        (def sums-path (path/join staging sums))
        (eprint "Downloading " (assets sums))
        (download (assets sums) sums-path)
        (eprint "Downloading " (assets archive))
        (download (assets archive) archive-path true)
        (def expected (expected-checksum (slurp sums-path) archive))
        (unless expected
          (error (string sums " has no checksum for " archive)))
        (unless (= expected (sha256 archive-path))
          (error (string archive " does not match its checksum in " sums)))
        (run (string "unpacking " archive)
             [(program "tar") "-xzf" archive-path "-C" staging "herd"])
        (def unpacked (path/join staging "herd"))
        (unless (= :file (os/lstat unpacked :mode))
          (error (string archive " holds no herd executable")))
        (os/chmod unpacked 8r755)
        # A binary that does not run here, being built for another machine or
        # stopped by the system, is caught before it replaces one that does.
        (def answer
          (try (process/capture [unpacked "--version"])
            ([err] {:status 1 :out "" :err (string err)})))
        (def expected-version (string "herd " tag))
        (def reported (string/trim (answer :out)))
        (unless (zero? (answer :status))
          (def said (string/trim (string (answer :out) (answer :err))))
          (error (string "the herd in " archive " does not run here: "
                         (if (empty? said)
                           (string "it exited " (answer :status))
                           said))))
        (unless (= expected-version reported)
          (error (string "the herd in " archive " reports "
                         (describe reported) ", not " expected-version)))
        (os/rename unpacked executable))
      (report "Updated herd " current-version " to " tag ": " executable)
      :updated)))
