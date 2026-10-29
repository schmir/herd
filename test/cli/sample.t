--sample picks the repositories whose clone URL has a CRC-32 in the first
PERCENT percent of its range. These URLs fall at about 0.4 (beta),
8.2 (delta), 9.4 (epsilon), 16.6 (gamma), 58.1 (alpha) and 68.6 (zeta)
percent.

  $ . "$TESTDIR/setup.sh"
  $ cd "$HOME"
  $ cat >"$CONFIG/repos.json" <<'JSON'
  > [{"path": "src/alpha", "clone_url": "https://example.com/alpha.git"},
  >  {"path": "src/beta", "clone_url": "https://example.com/beta.git"},
  >  {"path": "src/gamma", "clone_url": "https://example.com/gamma.git"},
  >  {"path": "src/delta", "clone_url": "https://example.com/delta.git"},
  >  {"path": "src/epsilon", "clone_url": "https://example.com/epsilon.git"},
  >  {"path": "src/zeta", "clone_url": "https://example.com/zeta.git"}]
  > JSON

list shows which repositories a sample picks, in the configured order.

  $ herd list --sample 10
  $ROOT/home/src/beta\thttps://example.com/beta.git (esc)
  $ROOT/home/src/delta\thttps://example.com/delta.git (esc)
  $ROOT/home/src/epsilon\thttps://example.com/epsilon.git (esc)

A larger sample keeps what the smaller one picked.

  $ herd list --sample 20 | cut -f1
  $ROOT/home/src/beta
  $ROOT/home/src/gamma
  $ROOT/home/src/delta
  $ROOT/home/src/epsilon

LOW:HIGH picks a half-open range, as a slice does, so ranges that meet
share no repository. A missing HIGH is 100.

  $ herd list --sample 0:9 | cut -f1
  $ROOT/home/src/beta
  $ROOT/home/src/delta
  $ herd list --sample 9:20 | cut -f1
  $ROOT/home/src/gamma
  $ROOT/home/src/epsilon
  $ herd list --sample 60: | cut -f1
  $ROOT/home/src/zeta

run acts on the same repositories that list shows.

  $ for name in alpha beta gamma delta epsilon zeta; do mkdir -p src/$name/.git; done
  $ herd run -j 1 --sample 10 --show-output always pwd
  \xe2\x9c\x93 $ROOT/home/src/beta (esc)
  | $ROOT/home/src/beta
  
  \xe2\x9c\x93 $ROOT/home/src/delta (esc)
  | $ROOT/home/src/delta
  
  \xe2\x9c\x93 $ROOT/home/src/epsilon (esc)
  | $ROOT/home/src/epsilon
  3 succeeded, 0 failed, 0 skipped, 0 not checked out

It combines with --limit.

  $ herd run -j 1 --sample 10 -n 1 true
  Stopped after 1 of 3 repositories
  1 succeeded, 0 failed, 0 skipped, 0 not checked out

A sample that picks nothing says so.

  $ herd list --sample 70:
  No repository is left of the 6 selected by --sample 70:
  $ herd run --sample 70: true
  No repository is left of the 6 selected by --sample 70:
  0 succeeded, 0 failed, 0 skipped, 0 not checked out

Only whole percentages are read, so a slip such as 0.100 for 0:100 is a
mistake rather than a sample of 0.1 percent. A range must not be empty.

  $ for sample in 0.100 0 101 many 20:10 10:10 10:101; do herd list --sample $sample; done
  Invalid --sample: expected a whole percentage from 1 to 100, or LOW:HIGH with 0 <= LOW < HIGH <= 100
  Invalid --sample: expected a whole percentage from 1 to 100, or LOW:HIGH with 0 <= LOW < HIGH <= 100
  Invalid --sample: expected a whole percentage from 1 to 100, or LOW:HIGH with 0 <= LOW < HIGH <= 100
  Invalid --sample: expected a whole percentage from 1 to 100, or LOW:HIGH with 0 <= LOW < HIGH <= 100
  Invalid --sample: expected a whole percentage from 1 to 100, or LOW:HIGH with 0 <= LOW < HIGH <= 100
  Invalid --sample: expected a whole percentage from 1 to 100, or LOW:HIGH with 0 <= LOW < HIGH <= 100
  Invalid --sample: expected a whole percentage from 1 to 100, or LOW:HIGH with 0 <= LOW < HIGH <= 100
  [1]
