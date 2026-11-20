# Tests for the names of the platforms herd is released for.
(use spork/test)
(import ../src/platform)

(start-suite "platform")

(defn test-platform-names
  "Every built platform has the name its release archive carries, and others none."
  []
  (assert (= "linux-x86_64" (platform/name :linux :x64)))
  (assert (= "linux-aarch64" (platform/name :linux :aarch64)))
  (assert (= "macos-arm64" (platform/name :macos :aarch64)))
  (assert (= "macos-arm64" (platform/name :macos :arm64)))
  (assert (= "macos-x86_64" (platform/name :macos :x64)))
  (assert (= "openbsd-amd64" (platform/name :openbsd :x64)))
  (assert (= "openbsd-arm64" (platform/name :openbsd :aarch64)))
  (assert (= "openbsd-arm64" (platform/name :openbsd :arm64)))
  (assert (= "freebsd-amd64" (platform/name :freebsd :x64)))
  (assert (= "freebsd-arm64" (platform/name :freebsd :aarch64)))
  (assert (= "freebsd-arm64" (platform/name :freebsd :arm64)))
  (assert (nil? (platform/name :netbsd :x64)))
  (assert (nil? (platform/name :windows :x64)))
  (assert (nil? (platform/name :linux :riscv64))))

(test-platform-names)

(end-suite)
