(declare-project
  :name "herd"
  :description "manage multiple git/jj repositories"
  :license "GPL-3.0-only"
  :dependencies ["https://github.com/janet-lang/spork.git"])

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
         "checkout.janet"
         "clone.janet"
         "completions.janet"
         "config.janet"
         "discover.janet"
         "entries.janet"
         "filter.janet"
         "parallel.janet"
         "process.janet"
         "run.janet"
         "select.janet"
         "state.janet"
         "survey.janet"])
