{
  description = "Development environment for herd";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
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
        "x86_64-darwin"
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
          # What the test suite reaches for and nothing else. CI uses this
          # rather than the shell below, whose editor and container tooling is
          # built from source and would be rebuilt on every run.
          ci = pkgs.mkShell {
            packages = with pkgs; [
              janet
              jp
              jpm
              just
            ];
          };

          default = pkgs.mkShell {
            packages = with pkgs; [
              coreutils
              janet
              janet-format
              janet-lsp
              jp
              jpm
              jujutsu
              just
              podman
              prettier
              treefmt
            ];
          };
        }
      );
    };
}
