# Known issues

Behaviour `herd` gets wrong today, and knows it does. Each one is written so
it can be reproduced as it stands, and says what to do in the meantime.

## A half-written clone passes for a checkout

`herd` takes a directory holding `.git` or `.jj` to be a checkout, and never
asks whether the repository in it is complete. A clone writes that marker
first, so a clone the VCS was killed in the middle of, without the chance to
clean up after itself, leaves a directory that looks checked out:

```sh
$ herd clone        # the machine loses power while src/acme/api is cloning
$ herd clone
0 cloned, 1 already checked out, 0 blocked, 0 failed
```

The repository is never cloned again, `herd list --status` reports it as
`ok`, and `herd run` and `herd fetch` work in it as if it were whole, where
the VCS will fail or find nothing.

`herd clone` stopped from the terminal lets what is in flight finish rather
than killing it, and Git and Jujutsu remove a clone that fails, so this
takes a crash or a `kill -9`.

Until this is fixed, a repository that `herd fetch` fails in right after a
clone is one to look at and remove by hand before cloning again.

The fix is for the clone to write somewhere beside the target and move the
result into place once the VCS succeeds, so the target only ever holds a
finished clone.

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
