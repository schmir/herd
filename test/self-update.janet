# Tests for replacing herd with the latest release, or one named.
(use spork/test)
(import spork/path)
(import spork/sh)
(import ../src/self-update)

(start-suite "self-update")

(defn test-platform-names
  "Every built platform has the name its release archive carries, and others none."
  []
  (assert (= "linux-x86_64" (self-update/platform :linux :x64)))
  (assert (= "linux-aarch64" (self-update/platform :linux :aarch64)))
  (assert (= "macos-arm64" (self-update/platform :macos :aarch64)))
  (assert (= "macos-arm64" (self-update/platform :macos :arm64)))
  (assert (= "macos-x86_64" (self-update/platform :macos :x64)))
  (assert (= "openbsd-amd64" (self-update/platform :openbsd :x64)))
  (assert (= "openbsd-arm64" (self-update/platform :openbsd :aarch64)))
  (assert (= "openbsd-arm64" (self-update/platform :openbsd :arm64)))
  (assert (= "freebsd-amd64" (self-update/platform :freebsd :x64)))
  (assert (= "freebsd-arm64" (self-update/platform :freebsd :aarch64)))
  (assert (= "freebsd-arm64" (self-update/platform :freebsd :arm64)))
  (assert (nil? (self-update/platform :netbsd :x64)))
  (assert (nil? (self-update/platform :windows :x64)))
  (assert (nil? (self-update/platform :linux :riscv64))))

(defn test-asset-names
  "The archive and the checksum file are named as the release workflow names them."
  []
  (assert (= "herd-v1.2.0-macos-arm64.tar.gz"
             (self-update/archive-name "v1.2.0" "macos-arm64")))
  (assert (= "herd-v1.2.0-SHA256SUMS" (self-update/checksums-name "v1.2.0"))))

(defn test-release-tag
  "A version names its tag, with or without the v, and nothing else is a tag."
  []
  (assert (= "v0.3.1" (self-update/release-tag "v0.3.1")))
  (assert (= "v0.3.1" (self-update/release-tag "0.3.1")) "the v is added to a number")
  (assert (= "v1.0.0-rc_1" (self-update/release-tag "1.0.0-rc_1")))
  (assert (= "nightly" (self-update/release-tag "nightly")) "a tag need not be a number")
  (each bad ["" "../latest" "v1/x" "v1 x" "v1?x" "v1#x"]
    (assert-error (string (describe bad) " is no tag") (self-update/release-tag bad))))

(defn test-release-url
  "Releases are described beneath the base, as the GitHub API lays them out."
  []
  (assert (= "https://x/releases/latest" (self-update/release-url "https://x/releases" nil)))
  (assert (= "https://x/releases/tags/v1" (self-update/release-url "https://x/releases" "v1")))
  (def saved (os/getenv "HERD_RELEASES_URL"))
  (defer (os/setenv "HERD_RELEASES_URL" saved)
    (os/setenv "HERD_RELEASES_URL" nil)
    (assert (= self-update/default-releases-url (self-update/releases-url)))
    (os/setenv "HERD_RELEASES_URL" "")
    (assert (= self-update/default-releases-url (self-update/releases-url))
            "an empty variable names nothing")
    (os/setenv "HERD_RELEASES_URL" "file:///mirror/")
    (assert (= "file:///mirror" (self-update/releases-url)) "a trailing slash is dropped")))

(defn test-release-assets
  "A release description yields its tag and the download URL of each asset."
  []
  (def release
    (self-update/release-assets
      `{"tag_name": "v1.2.0",
        "assets": [{"name": "a.tar.gz", "browser_download_url": "https://x/a"},
                   {"browser_download_url": "https://x/nameless"},
                   {"name": "SUMS", "browser_download_url": "https://x/s"}]}`))
  (assert (= "v1.2.0" (release :tag)))
  (assert (deep= @{"a.tar.gz" "https://x/a" "SUMS" "https://x/s"} (release :assets))
          "an asset without a name is left out")
  (assert (deep= @{} ((self-update/release-assets `{"tag_name": "v1"}`) :assets))
          "a release without assets has none"))

(defn test-release-assets-rejects-what-is-no-release
  "Something that is not a release description says so."
  []
  (assert-error "not JSON" (self-update/release-assets "<html>"))
  (assert-error "no tag" (self-update/release-assets `{"message": "Not Found"}`))
  (assert-error "no object" (self-update/release-assets `[1, 2]`)))

(defn test-expected-checksum
  "The hash of the named file, as sha256sum writes it in text or binary mode."
  []
  (def sums (string "aaa  herd-v1-linux-x86_64.tar.gz\n"
                    "bbb *herd-v1-macos-arm64.tar.gz\n"))
  (assert (= "aaa" (self-update/expected-checksum sums "herd-v1-linux-x86_64.tar.gz")))
  (assert (= "bbb" (self-update/expected-checksum sums "herd-v1-macos-arm64.tar.gz")))
  (assert (nil? (self-update/expected-checksum sums "herd-v1-macos-x86_64.tar.gz")))
  (assert (nil? (self-update/expected-checksum "" "anything"))))

(def dir (path/join (os/getenv "TMPDIR" "/tmp")
                    (string "herd-self-update-test-" (os/getpid))))
(sh/rm dir)
(sh/create-dirs dir)
(def real-dir (os/realpath dir))

(defn test-sha256
  "The checksum of a file is its SHA-256 in hex."
  []
  (def file (path/join dir "hello"))
  (spit file "hello\n")
  (assert (= "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
             (self-update/sha256 file))))

(defn test-own-executable
  "A path is taken as it is, a bare name is found on PATH, and links are resolved."
  []
  (def program (path/join dir "prog"))
  (spit program "#!/bin/sh\n")
  (os/chmod program 8r755)
  (def link (path/join dir "link"))
  (sh/rm link)
  (os/symlink program link)
  (def real (path/join real-dir "prog"))
  (assert (= real (self-update/own-executable program)))
  (assert (= real (self-update/own-executable link)) "a link leads to its file")
  (def saved-path (os/getenv "PATH"))
  (defer (os/setenv "PATH" saved-path)
    (os/setenv "PATH" dir)
    (assert (= real (self-update/own-executable "link")) "a bare name is found on PATH")
    (assert-error "not on PATH" (self-update/own-executable "absent"))))

(defn- with-env
  ``Call `f` with the variables `env` names set, and restore them after. `env`
  holds names and values in turn, a nil value unsetting its variable: a struct
  would drop the names whose value is nil.``
  [env f]
  (def pairs (partition 2 env))
  (def saved (map (fn [[name _]] [name (os/getenv name)]) pairs))
  (defer (each [name value] saved (os/setenv name value))
    (each [name value] pairs (os/setenv name value))
    (f)))

(defn test-github-token
  "GH_TOKEN wins over GITHUB_TOKEN, as with gh, and an empty one is none."
  []
  (with-env ["GH_TOKEN" "gh" "GITHUB_TOKEN" "github"]
    (fn [] (assert (= "gh" (self-update/github-token)))))
  (with-env ["GH_TOKEN" "" "GITHUB_TOKEN" "github"]
    (fn [] (assert (= "github" (self-update/github-token)))))
  (with-env ["GH_TOKEN" nil "GITHUB_TOKEN" nil]
    (fn [] (assert (nil? (self-update/github-token))))))

(defn test-authorization
  "Only a request to GitHub's API carries the token, quoted for curl."
  []
  (def api "https://api.github.com/repos/schmir/herd/releases/latest")
  (assert (= "header = \"Authorization: Bearer abc\"\n"
             (self-update/authorization api "abc")))
  (assert (= `header = "Authorization: Bearer a\"b\\c"` (string/trimr (self-update/authorization api `a"b\c`)))
          "a quote or backslash cannot end the header early")
  (assert (nil? (self-update/authorization api nil)) "no token, no header")
  (each url ["https://github.com/schmir/herd/releases/download/v1/herd.tar.gz"
             "https://mirror.example/releases/latest"
             "https://api.github.com.example/releases/latest"
             "file:///release/latest"]
    (assert (nil? (self-update/authorization url "abc"))
            (string "no token for " url))))

(defn test-fetch-hands-curl-the-token-on-stdin
  "The token reaches curl on its standard input and never on its command line."
  []
  (def bin (path/join dir "fake-curl"))
  (sh/create-dirs bin)
  (def curl (path/join bin "curl"))
  (spit curl (string "#!/bin/sh\n"
                     "printf '%s\\n' \"$@\" >" dir "/curl.args\n"
                     "cat >" dir "/curl.stdin\n"
                     "echo body\n"))
  (os/chmod curl 8r755)
  # The fake finds cat and the rest of the system where it usually is.
  (with-env ["PATH" (string bin ":/usr/bin:/bin") "GH_TOKEN" "s3cret" "GITHUB_TOKEN" nil]
    (fn []
      (assert (= "body\n" (self-update/fetch "https://api.github.com/x")))
      (def args (slurp (path/join dir "curl.args")))
      (assert (not (string/find "s3cret" args)) "the token is not an argument")
      (assert (string/find "-K\n-\n" args) "curl reads a configuration on stdin")
      (assert (= "header = \"Authorization: Bearer s3cret\"\n"
                 (string (slurp (path/join dir "curl.stdin")))))
      (self-update/fetch "https://mirror.example/x")
      (assert (not (string/find "-K" (slurp (path/join dir "curl.args"))))
              "a mirror gets no configuration")
      (assert (empty? (slurp (path/join dir "curl.stdin")))
              "and nothing on stdin"))))

(defn test-failure-hint
  "A status a token explains gets a hint, and only from GitHub's API."
  []
  (def api "https://api.github.com/repos/schmir/herd/releases/latest")
  (def failed (fn [code] (string "curl: (22) The requested URL returned error: " code)))
  (assert (string/find "limiting requests" (self-update/failure-hint (failed 403) api nil)))
  (assert (string/find "limiting requests" (self-update/failure-hint (failed 429) api nil)))
  (assert (string/find "rejected the token" (self-update/failure-hint (failed 401) api "t")))
  (assert (= "" (self-update/failure-hint (failed 403) api "t"))
          "a limit despite a token is not the token's to explain")
  (assert (= "" (self-update/failure-hint (failed 404) api nil)))
  (assert (= "" (self-update/failure-hint (failed 403) "https://mirror.example/latest" nil))
          "a mirror's refusal says nothing about GitHub"))

(test-platform-names)
(test-asset-names)
(test-release-tag)
(test-release-url)
(test-release-assets)
(test-release-assets-rejects-what-is-no-release)
(test-expected-checksum)
(test-sha256)
(test-own-executable)
(test-github-token)
(test-authorization)
(test-fetch-hands-curl-the-token-on-stdin)
(test-failure-hint)

(sh/rm dir)

(end-suite)
