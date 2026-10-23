# .janet-path

The module path for editor tooling. The Nix devshell sets `JANET_PATH` to
this directory.

`janet-lsp` finds definitions by evaluating a file and its imports, using a
bare `janet`. That `janet` cannot see `spork` (installed into `jpm_tree` by
`jpm deps`) or the native `access` module (built into `build/` by
`just build`), because only `jpm` and the justfile put those on the module
path. Without them an import fails and every lookup answers "no definition".

The symlinks here reach both. They dangle until `jpm deps` and `just build`
have run.
