# Known issues

Behaviour `herd` gets wrong today, and knows it does. Each one is written so
it can be reproduced as it stands, and says what to do in the meantime.

## A directory holding anything at all passes for a checkout

`herd clone` decides a repository is already checked out by looking for a
directory that is not empty, and never asks what is in it. A single stray
file is enough:

```sh
$ mkdir -p ~/src/acme/api && touch ~/src/acme/api/.DS_Store
$ herd clone
0 cloned, 1 already checked out, 0 failed
```

The repository is never cloned, and `clone` goes on reporting that it has
nothing to do for as long as the directory stays that way. The other
commands do not agree with it, or with each other: `herd run` runs the
command there, in a directory holding no working copy at all, while
`herd fetch` counts it a failure for having no `.git` or `.jj` to fetch
into.

An interrupted clone arrives at the same state by an ordinary route.
`herd clone` stopped from the terminal lets what is in flight finish rather
than killing it, but a clone the VCS itself left half written is a directory
with something in it like any other, and the next `herd clone` will pass
over it.

Until this is fixed, a repository that `herd clone` insists is already
checked out, and that `herd fetch` fails, is one to look at and remove by
hand before cloning again. `herd list` names every configured repository
whether or not it is checked out, so it is the list to check against.

The fix is for the test to be the one `repository-vcs` already applies
elsewhere: a checkout is a directory holding `.git` or `.jj`, and a
directory holding neither is occupied rather than checked out, which is a
third answer none of the commands can give yet.

## An anchor beginning with `~` is taken literally

A relative `:anchor` resolves from `$HOME` already, so writing `~/` in front
of one is redundant. It is not an error, though, and it is not expanded
either: the `~` becomes a directory of that name.

```janet
{:checkouts [{:from "repos.json" :anchor "~/src"}]}
```

```sh
$ herd list
/home/you/~/src/acme/api	git@github.com:acme/api.git
```

`herd clone` will create that directory rather than refuse it, leaving a
checkout somewhere nobody meant. A `$HOME/src` written instead of `~/src`
goes the same way, for the same reason: what a shell expands before a
program sees it, a configuration file does not.

Write a relative anchor with no prefix at all — `src`, not `~/src` — and it
resolves under `$HOME` as intended. An anchor that should not resolve from
`$HOME` is written absolute, and is used exactly as written.

The fix is to reject a leading `~` or `$` where the anchor is validated,
since neither can be meant literally by anyone.
