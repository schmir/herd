ssh asks on the terminal even with standard input closed, which would hang a
clone nobody can answer, such as one of a host not known yet. When jj runs it,
ssh is told to fail instead, as clone.t checks for Git.

  $ command -v jj > /dev/null || exit 80
  $ . "$TESTDIR/setup.sh"
  $ cd "$HOME"

  $ cat >"$ROOT/bin/ssh" <<EOF
  > #!/bin/sh
  > echo "\$SSH_ASKPASS_REQUIRE \$SSH_ASKPASS" >>"$ROOT/ssh.env"
  > exit 255
  > EOF
  $ chmod +x "$ROOT/bin/ssh"
  $ cat >"$CONFIG/ssh.json" <<EOF
  > [{"path": "src/over-jj", "ssh_url": "git@example.invalid:over.git", "vcs": "jj"}]
  > EOF
  $ herd clone -j 1 -C src/over-jj > /dev/null
  [1]
  $ cat "$ROOT/ssh.env"
  force false
