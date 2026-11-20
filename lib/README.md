# lib

The module path of the host's `janet`: the build sets `JANET_PATH` to this
directory when it makes the image, the justfile does when it runs the
sources and the tests, and the Nix devshell does for editor tooling such as
`janet-lsp`.

It holds what `src/` imports: the link `spork`, to the checkout in
`deps/spork`, and the native `access` and `terminal` modules, which the
build compiles into this directory. A native module is found by its bare
name, such as `access`. Until `just build`, or any recipe that builds the
natives target, has run, the link dangles and the modules are missing.
