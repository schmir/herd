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

**Catalog**: Every repository that the configuration files define after
their checkout rows and list filters have been applied. _Avoid_: Registry,
inventory

**Selection**: The repositories a command acts on, chosen from the catalog
by location, then by state and shell filters. _Avoid_: Matching, targeting

**List filter**: A named JMESPath expression that narrows a repository list
before it is read into the catalog. _Avoid_: Name filter, jp filter

**Checkout filter**: A named shell command, or a command given with `-f`,
that keeps the repositories it succeeds in. _Avoid_: Shell filter, sh filter
