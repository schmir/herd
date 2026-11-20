# The names of the platforms herd is released for.
#
# This module imports nothing, so that tools/gen-ninja.janet can load it
# before the native modules are built.

(defn name
  ``The release platform name for `os` and `arch`, as os/which and os/arch
  name them, or nil when no release is built for it. The names are those
  tools/gen-ninja.janet builds.``
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
