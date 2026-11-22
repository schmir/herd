Shell completion scripts, and the command list they ask herd for.

  $ . "$TESTDIR/setup.sh"

Each supported shell gets a script.

  $ herd completions bash | head -1
  # bash completion for herd. Source it, or save it where bash-completion
  $ herd completions zsh | head -1
  #compdef herd
  $ herd completions fish | head -1
  # fish completion for herd: herd completions fish | source

Anything else is a mistake.

  $ herd completions tcsh
  herd completions needs one of: bash, fish, zsh
  [1]
  $ herd completions
  herd completions needs one of: bash, fish, zsh
  [1]

The scripts learn the commands from herd itself, so the ones the
configuration defines are offered too.

  $ cat >"$CONFIG/config.jdn" <<'JDN'
  > {:commands {"greet" {:command "echo hi" :description "Say hi."}}
  >  :filters {"tier1"  {:jp "[?tier == `1`]"}
  >            "active" "[?active]"
  >            "has-readme" {:sh "test -f README.md"}
  >            "tier2"  {:jp "[?tier == `2`]" :doc "Repositories of the second tier."}
  >            "has-tests" {:sh "test -d test" :doc "Has a test directory."}}}
  > JDN
  $ herd completions commands
  clone\tCheck out the configured repositories beneath a path. (esc)
  completions\tPrint a shell completion script for herd. (esc)
  diff\tShow working copy changes in configured repositories beneath a path. (esc)
  fetch\tFetch Git remotes in configured repositories beneath a path. (esc)
  greet\tSay hi. (esc)
  list\tPrint the configured repositories beneath a path. (esc)
  run\tRun a command in each configured repository beneath a path. (esc)
  self-update\tReplace this herd with the latest release. (esc)
  tree\tPrint the repositories as a tree of the filesystem. (esc)

So are the configured filters, for the option that names one. A filter
shows its :doc, or its expression or command when it has none.

  $ herd completions filters
  active\t[?active] (esc)
  has-readme\ttest -f README.md (esc)
  has-tests\tHas a test directory. (esc)
  tier1\t[?tier == `1`] (esc)
  tier2\tRepositories of the second tier. (esc)
