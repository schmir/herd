(declare-project
  :name "herd"
  :description "manage multiple git/jj repositories"
  :dependencies ["https://github.com/janet-lang/spork.git"])

(declare-executable
  :name "herd"
  :entry "main.janet")
