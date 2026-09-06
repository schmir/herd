(declare-project
  :name "herd"
  :description "manage multiple git/jj repositories"
  :license "GPL-3.0-only"
  :dependencies ["https://github.com/janet-lang/spork.git"])

(declare-executable
  :name "herd"
  :entry "main.janet"
  :deps ["parallel.janet"])
