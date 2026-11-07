{
  description = "Development environment for herd";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.janet-lsp-nix = {
    url = "github:Blue-Berry/janet-lsp.nix";
    flake = false;
  };
  inputs.spork = {
    url = "github:janet-lang/spork";
    flake = false;
  };

  outputs =
    {
      janet-lsp-nix,
      nixpkgs,
      spork,
      ...
    }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          janet-format = pkgs.writeShellScriptBin "janet-format" ''
            exec ${pkgs.janet}/bin/janet --syspath ${spork} ${spork}/bin/janet-format "$@"
          '';
          janet-lsp = pkgs.callPackage janet-lsp-nix { };
        in
        {
          # What the test suite and the release build reach for and nothing
          # else. CI uses this rather than the shell below, whose editor
          # tooling is built from source and would be rebuilt on every run.
          ci = pkgs.mkShell {
            packages = with pkgs; [
              janet
              jp
              jpm
              just
              ninja
              zig
            ];
          };

          default = pkgs.mkShell {
            packages = with pkgs; [
              # The shells `just test-cli-shells` runs the command-line tests
              # under, standing in for the sh of the platforms herd ships for.
              bash
              coreutils
              dash
              gitMinimal
              janet
              janet-format
              janet-lsp
              jp
              jpm
              jujutsu
              just
              mksh
              ninja
              prettier
              treefmt
              uv
              zig
            ]
            # busybox builds only for Linux.
            ++ pkgs.lib.optional pkgs.stdenv.isLinux pkgs.busybox;

            # janet-lsp needs spork and the native modules on the module path;
            # see .janet-path/README.md.
            shellHook = ''
              root="$PWD"
              while [ ! -d "$root/.janet-path" ] && [ -n "$root" ]; do
                root="''${root%/*}"
              done
              [ -n "$root" ] || root="$PWD"
              export JANET_PATH="$root/.janet-path"
              unset root
            '';
          };
        }
      );
    };
}
