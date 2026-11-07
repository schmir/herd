# The commits to build from are in pins.jdn, which tools/gen-ninja.janet reads too.
(def- pins (parse (slurp "pins.jdn")))

(declare-project
  :name "herd"
  :description "manage multiple git/jj repositories"
  :license "GPL-3.0-only"
  :dependencies [{:url "https://github.com/janet-lang/spork.git"
                  :tag (pins :spork)}])

# Janet binds no access(2), and the permission bits alone cannot say whether
# this process may execute a file. See src/access.c.
(declare-native
  :name "access"
  :source ["src/access.c"])

# spork's rawterm/size asks stdin and cannot say when there is no terminal.
# See src/terminal.c.
(declare-native
  :name "terminal"
  :source ["src/terminal.c"])

(declare-executable
  :name "herd"
  :entry "src/main.janet"
  :deps ["build/access.so"
         "build/access.meta.janet"
         "build/terminal.so"
         "build/terminal.meta.janet"
         "src/arguments.janet"
         "src/checkout.janet"
         "src/clone.janet"
         "src/completions.janet"
         "src/config.janet"
         "src/discover.janet"
         "src/named-filters.janet"
         "src/location.janet"
         "src/options.janet"
         "src/pager.janet"
         "src/parallel.janet"
         "src/process.janet"
         "src/run.janet"
         "src/sample.janet"
         "src/selection.janet"
         "src/self-update.janet"
         "src/stages.janet"
         "src/survey.janet"
         "src/tree.janet"
         "src/vcs.janet"])
