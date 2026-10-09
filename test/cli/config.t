A configuration herd cannot use is an error that names the file and the
mistake, whichever command reads it.

  $ . "$TESTDIR/setup.sh"
  $ two_repos

  $ echo '[' >"$CONFIG/broken.json"
  $ herd list
  Configuration error: $ROOT/home/.config/herd/broken.json: decode error at position 2: unexpected end of source
  [1]

  $ echo '[{"path": "src/x"}]' >"$CONFIG/broken.json"
  $ herd clone
  Configuration error: $ROOT/home/.config/herd/broken.json: entry 0 needs a string "ssh_url"
  [1]

The same path is accepted twice only when both say the same about it.

  $ echo '[{"path": "src/api", "ssh_url": "elsewhere", "vcs": "git"}]' \
  >   >"$CONFIG/broken.json"
  $ herd list
  Configuration error: $ROOT/home/.config/herd/broken.json and $ROOT/home/.config/herd/repos.json disagree on the URL for $ROOT/home/src/api
  [1]
  $ rm "$CONFIG/broken.json"

A :checkouts row has to read a list that exists.

  $ echo '{:checkouts [{:from "gone.json"}]}' >"$CONFIG/config.jdn"
  $ herd list
  Configuration error: config.jdn: :checkouts reads "gone.json", which is not in the configuration directory
  [1]

  $ echo '{:jobs 0}' >"$CONFIG/config.jdn"
  $ herd list
  Configuration error: $ROOT/home/.config/herd/config.jdn: :jobs must be a positive integer no greater than 2147483647
  [1]

A custom command cannot take a built-in name, and the error stops --help
too.

  $ echo '{:commands {"list" {:command "true" :description "x"}}}' \
  >   >"$CONFIG/config.jdn"
  $ herd --help
  Configuration error: $ROOT/home/.config/herd/config.jdn: custom command "list" conflicts with a built-in command
  [1]

Each entry in a list is checked.

  $ rm "$CONFIG/config.jdn"
  $ cp "$CONFIG/repos.json" repos.json.saved
  $ entries() { echo "$1" >"$CONFIG/repos.json"; herd list > /dev/null || herd list; }
  $ entries '{"path": "a", "ssh_url": "b"}'
  Configuration error: $ROOT/home/.config/herd/repos.json: expected a JSON array of repository objects
  [1]
  $ entries '[42]'
  Configuration error: $ROOT/home/.config/herd/repos.json: entry 0 is not a JSON object
  [1]
  $ entries '[{"ssh_url": "b"}]'
  Configuration error: $ROOT/home/.config/herd/repos.json: entry 0 needs a string "path"
  [1]
  $ entries '[{"path": 1, "ssh_url": "b"}]'
  Configuration error: $ROOT/home/.config/herd/repos.json: entry 0 needs a string "path"
  [1]
  $ entries '[{"path": "a", "ssh_url": "b", "vcs": "svn"}]'
  Configuration error: $ROOT/home/.config/herd/repos.json: entry 0 has an invalid "vcs"; expected "git" or "jj"
  [1]
  $ entries '[{"path": "a", "ssh_url": "b", "vcs": false}]'
  Configuration error: $ROOT/home/.config/herd/repos.json: entry 0 has an invalid "vcs"; expected "git" or "jj"
  [1]
  $ entries '[]'
  $ cp repos.json.saved "$CONFIG/repos.json"

So are the settings in config.jdn. They are data, never run as code.

  $ settings() { echo "$1" >"$CONFIG/config.jdn"; herd list > /dev/null || herd list; }
  $ settings '(error "this code must not run")'
  Configuration error: $ROOT/home/.config/herd/config.jdn: expected a JDN dictionary
  [1]
  $ settings '{:jobs 3} {:commands {}}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: expected one dictionary of settings, but the file holds 2 top-level values
  [1]
  $ settings '# nothing configured yet'
  $ settings '{:jobs -2}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :jobs must be a positive integer no greater than 2147483647
  [1]
  $ settings '{:jobs 1.5}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :jobs must be a positive integer no greater than 2147483647
  [1]
  $ settings '{:jobs "4"}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :jobs must be a positive integer no greater than 2147483647
  [1]

Custom commands.

  $ settings '{:commands []}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :commands must be a dictionary
  [1]
  $ settings '{:commands {"check" {:description "Check."}}}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: custom command "check" needs :command, :command-git, or :command-jj
  [1]
  $ settings '{:commands {"check" {:command "true"}}}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: custom command "check" needs a string :description
  [1]
  $ settings '{:commands {"check" {:command-git "git status" :comand-jj "jj st" :description "Check."}}}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: custom command "check" has an unknown key :comand-jj
  [1]
  $ settings '{:commands {"check" {:command "st" :command-git "git status" :description "Check."}}}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: custom command "check" cannot combine :command with VCS-specific commands
  [1]
  $ settings '{:commands {"check" {:command "true" :description "Check." :show-output :always}}}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: custom command "check" has an invalid :show-output; expected "never", "on-failure", or "always"
  [1]
  $ settings '{:commands {"check" {:command "true" :description "Check." :show-output "sometimes"}}}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: custom command "check" has an invalid :show-output; expected "never", "on-failure", or "always"
  [1]
  $ settings '{:commands {"check" {:command-jj "jj st" :description "Check."}}}'

:checkouts rows and :defaults.

  $ settings '{:checkouts {}}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :checkouts must be an array of rows
  [1]
  $ settings '{:checkouts [[]]}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :checkouts row 0 must be a dictionary
  [1]
  $ settings '{:checkouts [{:anchor "work"}]}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :checkouts row 0 needs a :from naming a configuration file
  [1]
  $ settings '{:checkouts [{:from 1}]}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :checkouts row 0 needs a :from naming a configuration file
  [1]
  $ settings '{:checkouts [{:from ""}]}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :checkouts row 0 needs a :from naming a configuration file
  [1]
  $ settings '{:checkouts [{:from "repos.json" :anchor ""}]}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :checkouts row 0 needs a non-empty :anchor
  [1]
  $ settings '{:checkouts [{:from "repos.json" :jobs 2}]}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :checkouts row 0 has an unknown setting :jobs
  [1]
  $ settings '{:checkouts [{:from "repos.json" :anchors ["work"]}]}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :checkouts row 0 has an unknown setting :anchors
  [1]
  $ settings '{:checkouts [{:from "repos.json" :vcs "svn"}]}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :checkouts row 0 has an invalid :vcs; expected "git" or "jj"
  [1]
  $ settings '{:checkouts [{:from "repos.json" :strip-components 1.5}]}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :checkouts row 0 needs a non-negative integer in :strip-components
  [1]
  $ settings '{:checkouts [{:from "repos.json" :strip-components -1}]}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :checkouts row 0 needs a non-negative integer in :strip-components
  [1]
  $ settings '{:checkouts [{:from "repos.json"} {:unknown true}]}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :checkouts row 1 has an unknown setting :unknown
  [1]
  $ settings '{:defaults []}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :defaults must be a dictionary
  [1]
  $ settings '{:defaults {:from "repos.json"}}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :defaults has an unknown setting :from
  [1]
  $ settings '{:defaults {:strip-components 1}}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :defaults has an unknown setting :strip-components
  [1]
  $ settings '{:defaults {:vcs "svn"}}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :defaults has an invalid :vcs; expected "git" or "jj"
  [1]

Stripping more components than a path has.

  $ settings '{:checkouts [{:from "repos.json" :strip-components 2}]}'
  Configuration error: $ROOT/home/.config/herd/repos.json: the row anchored at "$ROOT/home" cannot strip 2 components from path "src/api"; no components remain
  [1]

Filters, and the rows and defaults that name them.

  $ settings '{:filters []}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :filters must be a dictionary of names to filters
  [1]
  $ settings '{:filters {"active" 1}}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: filter "active" needs an expression, or a dictionary with :jp or :sh
  [1]
  $ settings '{:filters {"active" ""}}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: filter "active" needs a non-empty expression
  [1]
  $ settings '{:checkouts [{:from "repos.json" :filter "active"}]}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :checkouts row 0 needs an array of filter names in :filter
  [1]
  $ settings '{:checkouts [{:from "repos.json" :filter [""]}]}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :checkouts row 0 names an invalid filter ""; expected a non-empty string
  [1]
  $ settings '{:filters {"active" "[?a]"} :checkouts [{:from "repos.json" :filter ["typo"]}]}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :checkouts row for "repos.json" names an unknown filter "typo"
  [1]
  $ settings '{:defaults {:filter ["absent"]}}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :defaults names an unknown filter "absent"
  [1]

A filter can say what it is: a JMESPath expression in :jp, or a shell
command in :sh, exactly one of them. A string stays a JMESPath expression.

  $ settings '{:filters {"a" {:jp "[?a]"} "b" {:sh "true"} "c" "[?c]"}}'
  $ settings '{:filters {"a" {}}}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: filter "a" needs exactly one of :jp and :sh
  [1]
  $ settings '{:filters {"a" {:jp "[?a]" :sh "true"}}}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: filter "a" needs exactly one of :jp and :sh
  [1]
  $ settings '{:filters {"a" {:sh ""}}}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: filter "a" needs a non-empty string in :sh
  [1]
  $ settings '{:filters {"a" {:sh "true" :other 1}}}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: filter "a" has an unknown key :other
  [1]

A shell filter runs in a checkout, so a row or the defaults cannot name one.

  $ settings '{:filters {"b" {:sh "true"}} :checkouts [{:from "repos.json" :filter ["b"]}]}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :checkouts row for "repos.json" names the command filter "b", which only the command line can use
  [1]
  $ settings '{:filters {"b" {:sh "true"}} :defaults {:filter ["b"]}}'
  Configuration error: $ROOT/home/.config/herd/config.jdn: :defaults names the command filter "b", which only the command line can use
  [1]

Only *.json files are lists, and a directory named like one is not.

  $ rm "$CONFIG/config.jdn"
  $ echo ignored >"$CONFIG/notes.txt"
  $ mkdir "$CONFIG/directory.json"
  $ herd list -C "$HOME"
  $ROOT/home/src/api\t$ROOT/origins/api (esc)
  $ROOT/home/src/web\t$ROOT/origins/web (esc)

A file where the configuration directory belongs is an error.

  $ rm -r "$CONFIG"
  $ echo 'not a directory' >"$CONFIG"
  $ herd list
  Configuration error: cannot open directory $ROOT/home/.config/herd: Not a directory
  [1]
