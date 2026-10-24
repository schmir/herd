# herd

herd runs commands across many repositories that are listed in repository
list files and checked out under configured directories.

## Language

**Repository**: One entry of a repository list, resolved to a path under an
anchor, whether or not it is checked out. _Avoid_: Project, checkout (a
checkout is the on-disk copy of a repository)

**Anchor**: The directory a checkout row resolves the relative paths of its
repository list against. One list can be anchored at several directories.
_Avoid_: Root, base directory

**Repository list**: A JSON file in the configuration directory that lists
repositories by path and URL. The catalog is built from all of them.
_Avoid_: Config file, list file

**Settings file**: `config.jdn`, which holds the filters, defaults, checkout
rows, job count and custom commands. _Avoid_: Command config

**Checkout row**: One entry of `:checkouts` in `config.jdn`: it reads a
repository list (`:from`) and places it under an anchor, with its own
filters, stripped path components and repository options. Not a checkout in
the on-disk sense. _Avoid_: Row, source, mapping

**Placement**: A checkout row with its anchor resolved to a directory, as
the code reads a list through it. _Avoid_: Resolved anchor

**Subcommand**: A command of the herd program itself, such as `clone`,
`list`, `run` or `completions`, or a custom command. _Avoid_: Verb, action

**Custom command**: A subcommand that `:commands` in the settings file
defines. It runs a command in each repository, with a `:command` or, per
VCS, a `:command-git` and `:command-jj`. _Avoid_: Alias, task

**Catalog**: Every repository that the repository lists define after their
checkout rows and list filters have been applied. _Avoid_: Registry,
inventory

**Selection**: The repositories a command acts on, chosen from the catalog
by location, then by state and checkout filters. _Avoid_: Matching,
targeting

**Filter registry**: The named filters `config.jdn` defines, each a list
filter or a checkout filter. _Avoid_: Filter table, filter map

**List filter**: A named JMESPath expression that narrows a repository list
before it is read into the catalog. _Avoid_: Name filter, jp filter

**Checkout filter**: A named shell command, or a command given with `-f`,
that keeps the repositories it succeeds in. _Avoid_: Shell filter, sh filter
