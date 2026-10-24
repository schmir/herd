(declare-project
  :name "herd"
  :description "manage multiple git/jj repositories"
  :license "GPL-3.0-only"
  :dependencies [{:url "https://github.com/janet-lang/spork.git"
                  :tag "26af769b7fd8f7214ea8f95dad5c2d360a79f6b4"}])

# Janet binds no access(2), and the permission bits alone cannot say whether
# this process may execute a file. See access.c.
(declare-native
  :name "access"
  :source ["access.c"])

(declare-executable
  :name "herd"
  :entry "main.janet"
  :deps ["build/access.so"
         "build/access.meta.janet"
         "arguments.janet"
         "checkout.janet"
         "clone.janet"
         "completions.janet"
         "config.janet"
         "discover.janet"
         "named-filters.janet"
         "location.janet"
         "options.janet"
         "parallel.janet"
         "process.janet"
         "run.janet"
         "selection.janet"
         "stages.janet"
         "survey.janet"
         "vcs.janet"])
