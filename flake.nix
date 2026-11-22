{
  description = "Development environment for herd";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      # The pins of pins.env, as an attribute set of its KEY=value lines.
      pins = builtins.listToAttrs (
        map
          (kv: {
            name = builtins.elemAt kv 0;
            value = builtins.elemAt kv 1;
          })
          (
            builtins.filter (kv: kv != null) (
              map (builtins.match "([A-Z_]+)=(.*)") (nixpkgs.lib.splitString "\n" (builtins.readFile ./pins.env))
            )
          )
      );
      # The sources that pins.env pins. The commit identifies the source, so
      # no hash is necessary, and pins.env stays the one place to change it.
      fetchPinned =
        repo: rev:
        builtins.fetchGit {
          url = "https://github.com/janet-lang/${repo}";
          inherit rev;
          shallow = true;
        };
      pinned-janet-src = fetchPinned "janet" pins.JANET_COMMIT;
      pinned-spork-src = fetchPinned "spork" pins.SPORK_COMMIT;
      pinned-janet-version = builtins.head (
        builtins.match ''.*#define JANET_VERSION "([^"]*)".*'' (
          builtins.readFile "${pinned-janet-src}/src/conf/janetconf.h"
        )
      );
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          janet-format = pkgs.writeShellScriptBin "janet-format" ''
            exec ${pkgs.janet}/bin/janet --syspath ${pinned-spork-src} ${pinned-spork-src}/bin/janet-format "$@"
          '';
          pinned-janet = pkgs.janet.overrideAttrs {
            version = pinned-janet-version;
            src = pinned-janet-src;
          };
          # janet-lsp loads the native modules in lib/, which are compiled
          # against the janet.h of the pinned Janet, so it must run that
          # release. Its release image cannot be used: in an image made by an
          # earlier Janet, Janet 1.43 loads the keywords of dynamic bindings,
          # such as :args, as nil. So build the image from source with the
          # pinned Janet.
          # The dependencies are the commits in its lockfile.jdn.
          janet-lsp-deps = {
            cmd = pkgs.fetchFromGitHub {
              owner = "cfiggers";
              repo = "cmd";
              rev = "b0a34d6e854578bd672d43303e80b9777af08b42";
              hash = "sha256-Kkwde3hHgbi8aj9ud6rOh13KWVxdNCNY4zXnDVj7uzA=";
            };
            judge = pkgs.fetchFromGitHub {
              owner = "cfiggers";
              repo = "judge";
              rev = "1d329cb3a7384c3ff0f6232e60d81aa9db3a5440";
              hash = "sha256-iR7bCEVvJK3lF9m4hXJhQ4JRnhvcGjgBrWuWIiYT7dg=";
            };
            spork = pkgs.fetchFromGitHub {
              owner = "janet-lang";
              repo = "spork";
              rev = "dbfc90d4c86fa54a74c56d406517605e49569a8b";
              hash = "sha256-NbQ7Ghu1VINlkMAzQfVUQRtLQ3sUOYjMnrfFV2H1ZNo=";
            };
          };
          janet-lsp = pkgs.stdenvNoCC.mkDerivation {
            pname = "janet-lsp";
            version = "0.0.13";
            src = pkgs.fetchFromGitHub {
              owner = "CFiggers";
              repo = "janet-lsp";
              rev = "v0.0.13";
              hash = "sha256-lJzTQmjQyyWq+HYEInJuPdcxUwz+KybI5jl0pj9jtIs=";
            };
            # main.janet asks git for the commit while it compiles, and fails
            # when git fails. The source is not a git repository, so a git that
            # prints the commit of the tag stands in. The commit must not be
            # empty: the server sends it to the client, and its JSON encoder
            # fails on an empty string.
            nativeBuildInputs = [
              (pkgs.writeShellScriptBin "git" "echo c3ec07d")
              pkgs.makeWrapper
            ];
            buildPhase = ''
              runHook preBuild
              mkdir modules
              ln -s ${janet-lsp-deps.cmd}/src modules/cmd
              ln -s ${janet-lsp-deps.judge}/src modules/judge
              ln -s ${janet-lsp-deps.spork}/spork modules/spork
              JANET_PATH=$PWD/modules ${pinned-janet}/bin/janet -c src/main.janet janet-lsp.jimage
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              install -Dm444 janet-lsp.jimage $out/share/janet-lsp/janet-lsp.jimage
              makeWrapper ${pinned-janet}/bin/janet $out/bin/janet-lsp \
                --add-flags "-i $out/share/janet-lsp/janet-lsp.jimage"
              runHook postInstall
            '';
            meta.mainProgram = "janet-lsp";
          };
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
                gitMinimal
                # tools/make-archives.sh needs the options of GNU tar, and
                # the tar of macOS is not GNU tar.
                gnutar
                jp
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
              shfmt
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

            env = pins;

            # janet-lsp needs spork and the native modules on the module path;
            # see lib/README.md. pins.env marks the root of the project.
            shellHook = ''
              root="$PWD"
              while [ ! -f "$root/pins.env" ] && [ -n "$root" ]; do
                root="''${root%/*}"
              done
              export JANET_PATH="''${root:-$PWD}/lib"
              unset root
            '';
          };
        }
      );
    };
}
