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
          # The shells `just test-cli-shells` runs the command-line tests
          # under, standing in for the sh of the platforms herd ships for.
          # busybox builds only for Linux, and its package links an applet for
          # every command into bin/, which would shadow coreutils on PATH. Only
          # the busybox binary itself goes into the shell.
          busybox-only = pkgs.runCommand "busybox-only" { } ''
            mkdir -p $out/bin
            ln -s ${pkgs.busybox}/bin/busybox $out/bin/busybox
          '';
          shells =
            with pkgs;
            [
              bash
              dash
              mksh
            ]
            ++ lib.optional stdenv.hostPlatform.isLinux busybox-only;
          # What the test suite and the release build reach for and nothing
          # else. CI uses this rather than the default shell, whose editor
          # tooling is built from source and would be rebuilt on every run.
          ci = pkgs.mkShell {
            packages =
              with pkgs;
              [
                janet
                jp
                jpm
                jujutsu
                just
                ninja
                zig
              ]
              ++ shells;
          };
          # What treefmt runs, for the format check in CI. Without git,
          # treefmt also formats the files that .gitignore lists.
          fmt = pkgs.mkShell {
            packages = with pkgs; [
              gitMinimal
              janet-format
              just
              nixfmt
              prettier
              ruff
              treefmt
              uv
            ];
          };
        in
        {
          inherit ci fmt;

          default = pkgs.mkShell {
            inputsFrom = [
              ci
              fmt
            ];
            packages = with pkgs; [
              coreutils
              janet-lsp
            ];

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
