How run reports what a command printed. The repositories are plain
directories, since run needs nothing more than one holding a .git.

  $ . "$TESTDIR/setup.sh"
  $ cd "$HOME"
  $ mkdir -p first/.git second/.git
  $ echo '[{"path": "first", "ssh_url": "u"}, {"path": "second", "ssh_url": "u"}]' \
  >   >"$CONFIG/repos.json"

A successful command stays quiet by default, and `always` shows stdout and
stderr in one block per repository.

  $ herd run -j 1 sh -c 'printf "hidden\ntext\n"; printf secret >&2'
  2 succeeded, 0 failed, 0 skipped, 0 not checked out

  $ herd run -j 1 --show-output always sh -c 'printf "visible\ntext\n"; printf note >&2'
  ✓ $ROOT/home/first
  | visible
  | text
  ! note
  
  ✓ $ROOT/home/second
  | visible
  | text
  ! note
  2 succeeded, 0 failed, 0 skipped, 0 not checked out

A command that printed nothing is not reported even with `always`.

  $ herd run --show-output always true
  2 succeeded, 0 failed, 0 skipped, 0 not checked out

A failure shows what the command printed, and names the repository even
when it printed nothing.

  $ herd run -j 1 sh -c 'printf "visible\nsecond line\n"; printf problem >&2; exit 7'
  ✗ $ROOT/home/first (exit 7)
  | visible
  | second line
  ! problem
  
  ✗ $ROOT/home/second (exit 7)
  | visible
  | second line
  ! problem
  0 succeeded, 2 failed, 0 skipped, 0 not checked out
  [1]

  $ herd run -j 1 false
  ✗ $ROOT/home/first (exit 1)
  
  ✗ $ROOT/home/second (exit 1)
  0 succeeded, 2 failed, 0 skipped, 0 not checked out
  [1]

never hides failures too.

  $ herd run --show-output never false
  0 succeeded, 2 failed, 0 skipped, 0 not checked out
  [1]

The command's own options need no separator.

  $ herd run sh -c 'touch -- "$1"' herd -command-argument
  2 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ ls first second
  first:
  -command-argument
  
  second:
  -command-argument

No shell reads the command, so its syntax means nothing: this names a program
called `true && true`, which is not there.

  $ herd run --show-output never 'true && true'
  0 succeeded, 2 failed, 0 skipped, 0 not checked out
  [1]
  $ herd run --show-output never sh -c 'true && true'
  2 succeeded, 0 failed, 0 skipped, 0 not checked out

One failure among successes fails herd.

  $ herd run -j 1 sh -c 'test "$HERD_REPO_PATH" = first'
  ✗ $ROOT/home/second (exit 1)
  1 succeeded, 1 failed, 0 skipped, 0 not checked out
  [1]

--jobs is how many run at once. With two, each command waits until the other
has started, which it could not do if they ran in turn. With one, each holds
a lock the other would fail to take if they overlapped.

  $ herd run -j 2 sh -c '
  >   touch "$HOME/started-$HERD_REPO_PATH"
  >   for _ in $(seq 100); do
  >     test -e "$HOME/started-first" && test -e "$HOME/started-second" && exit 0
  >     sleep 0.1
  >   done
  >   exit 1'
  2 succeeded, 0 failed, 0 skipped, 0 not checked out
  $ rm "$HOME"/started-*
  $ herd run -j 1 sh -c 'mkdir "$HOME/lock" && sleep 0.2 && rmdir "$HOME/lock"'
  2 succeeded, 0 failed, 0 skipped, 0 not checked out

A repository that is not there is counted, and does not stop the others.

  $ echo '[{"path": "missing", "ssh_url": "u"}]' >"$CONFIG/more.json"
  $ herd run touch ran
  2 succeeded, 0 failed, 0 skipped, 1 not checked out
  $ ls first/ran second/ran
  first/ran
  second/ran

Nor does it use up --limit: more.json is read first, so the missing repository
comes first, and the command still runs in the one after it.

  $ herd run -j 1 -n 1 touch limited
  Stopped after 2 of 3 repositories
  1 succeeded, 0 failed, 0 skipped, 1 not checked out
  $ ls */limited
  first/limited
