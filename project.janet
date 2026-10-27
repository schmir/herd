(declare-project
  :name "herd"
  :description "manage multiple git/jj repositories"
  :license "GPL-3.0-only"
  :dependencies [{:url "https://github.com/janet-lang/spork.git"
                  :tag "26af769b7fd8f7214ea8f95dad5c2d360a79f6b4"}])

# Janet binds no access(2), and the permission bits alone cannot say whether
# this process may execute a file. See src/access.c.
(declare-native
  :name "access"
  :source ["src/access.c"])

(declare-executable
  :name "herd"
  :entry "src/main.janet"
  :deps ["build/access.so"
         "build/access.meta.janet"
         "src/arguments.janet"
         "src/checkout.janet"
         "src/clone.janet"
         "src/completions.janet"
         "src/config.janet"
         "src/discover.janet"
         "src/named-filters.janet"
         "src/location.janet"
         "src/options.janet"
         "src/parallel.janet"
         "src/process.janet"
         "src/run.janet"
         "src/sample.janet"
         "src/selection.janet"
         "src/stages.janet"
         "src/survey.janet"
         "src/vcs.janet"])
