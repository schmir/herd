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

# tools/gen-ninja.py has its own table, keyed by the names Python gives the
# host, to choose the binary that build/herd copies. These tests check that
# it gives the names this module gives.

(def- python-table
  ``Print the host as Python names it, each entry of HOST_PLATFORMS in
  tools/gen-ninja.py, and each platform it builds, one per line.``
  ```
import importlib.util, platform
spec = importlib.util.spec_from_file_location("gen_ninja", "tools/gen-ninja.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print("host", platform.system(), platform.machine())
for (system, machine), name in module.HOST_PLATFORMS.items():
    print("entry", system, machine, name)
for name, _ in module.PLATFORMS:
    print("platform", name)
```)

(defn- read-python-table
  "Return the host, the table and the platforms of tools/gen-ninja.py."
  []
  (with [process (os/spawn ["uv" "run" "--no-project" "python" "-c" python-table]
                           :p {:out :pipe})]
    (def out @"")
    (ev/gather (:read (process :out) :all out) (:wait process))
    (assert (zero? (process :return-code)) "python prints the table")
    (def result @{:entries @{} :platforms @[]})
    (each line (string/split "\n" (string/trim out))
      (match (string/split " " line)
        ["host" system machine] (put result :host [system machine])
        ["entry" system machine name] (put-in result [:entries [system machine]] name)
        ["platform" name] (array/push (result :platforms) name)))
    result))

# How Janet names what Python names. Janet's os/arch is :aarch64 on ARM, but
# the table also takes :arm64.
(def- systems {"Linux" :linux "Darwin" :macos "OpenBSD" :openbsd "FreeBSD" :freebsd})
(def- machines {"x86_64" :x64 "amd64" :x64 "aarch64" :aarch64 "arm64" :arm64})

(def- python (read-python-table))

(defn test-gen-ninja-gives-the-names-herd-gives
  "Each entry of the table in tools/gen-ninja.py gives the name this module gives."
  []
  (eachp [[system machine] name] (python :entries)
    (def os (systems system))
    (def arch (machines machine))
    (assert (and os arch)
            (string/format "%s %s in tools/gen-ninja.py has a Janet name here" system machine))
    (def from-janet (and os arch (platform/name os arch)))
    (assert (= name from-janet)
            (string/format "%s %s: tools/gen-ninja.py gives %v, src/platform.janet %v"
                           system machine name from-janet))))

(defn test-gen-ninja-has-each-name-herd-gives
  ``Each name this module gives, and each platform tools/gen-ninja.py builds,
  has an entry in the table in tools/gen-ninja.py.``
  []
  (def from-python (values (python :entries)))
  (each name (python :platforms)
    (assert (index-of name from-python)
            (string/format "tools/gen-ninja.py builds %s but has no host entry for it" name)))
  (each os systems
    (each arch machines
      (when-let [name (platform/name os arch)]
        (assert (index-of name from-python)
                (string/format "tools/gen-ninja.py has no entry for %s (%v %v)" name os arch))))))

(defn test-gen-ninja-names-this-host-as-herd-does
  ``On this machine, the binary build/herd copies is the one herd self-update
  asks for. They differ when Python runs under emulation, such as an x86_64
  Python on an ARM Mac.``
  []
  (def from-python (get-in python [:entries (python :host)]))
  (def from-janet (platform/name (os/which) (os/arch)))
  (assert (= from-python from-janet)
          (string/format "tools/gen-ninja.py names this host %v, src/platform.janet %v"
                         from-python from-janet)))

(test-platform-names)
(test-gen-ninja-gives-the-names-herd-gives)
(test-gen-ninja-has-each-name-herd-gives)
(test-gen-ninja-names-this-host-as-herd-does)

(end-suite)
