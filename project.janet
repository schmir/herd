(declare-project
  :name "herd"
  :description "manage multiple git/jj repositories"
  :license "GPL-3.0-only"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# Janet binds no access(2), and the permission bits alone cannot say whether
# this process may execute a file. See access.c.
#
# The musl build links the executable against nothing at all, and jpm hands
# the link flags it is given to every link it drives. A shared object cannot
# be linked against a static libc, so this one names an empty set of its own
# and leaves -static to the executable.
(declare-native
  :name "access"
  :source ["access.c"]
  :lflags [])

(declare-executable
  :name "herd"
  :entry "main.janet"
  :deps ["build/access.so"
         "build/access.meta.janet"
         "checkout.janet"
         "clone.janet"
         "config.janet"
         "entries.janet"
         "filter.janet"
         "parallel.janet"
         "process.janet"
         "run.janet"
         "select.janet"])
