# Known issues

Behaviour `herd` gets wrong today, and knows it does. Each one is written so
it can be reproduced as it stands, and says what to do in the meantime.

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
