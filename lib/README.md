# lib

The module path of `build/janet`, the pinned Janet compiled for the host:
the build sets `JANET_PATH` to this directory when it makes the image, and
the justfile does when it runs the sources and the tests. The Nix devshell
sets it for editor tooling such as `janet-lsp`, which runs its own Janet.

It holds what `src/` imports: the link `spork`, to the checkout in
`deps/spork`, and the native `access` and `terminal` modules, which the
build compiles into this directory. A native module is found by its bare
name, such as `access`. Until `just build`, or any recipe that builds the
natives target, has run, the link dangles and the modules are missing.
