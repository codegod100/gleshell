{
  description = "gleshell — structured-data shell in Gleam, inspired by Nushell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";
    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";
  };

  nixConfig = {
    extra-substituters = [ "https://devenv.cachix.org" ];
    extra-trusted-public-keys = [
      "devenv.cachix.org-1:ppRjvZf4JrQqfA3n7eHkSxX4z1M0RKZ77N8D66zCFAI="
    ];
  };

  outputs =
    {
      self,
      nixpkgs,
      devenv,
      systems,
      ...
    }@inputs:
    let
      forEachSystem = nixpkgs.lib.genAttrs (import systems);
    in
    {
      packages = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          runtimeInputs = [
            pkgs.gleam
            pkgs.beamPackages.erlang
            pkgs.rebar3
          ];
          # Thin wrapper: needs the gleshell source tree (cwd or GLESHELL_ROOT).
          gleshell = pkgs.writeShellApplication {
            name = "gleshell";
            inherit runtimeInputs;
            text = ''
              root="''${GLESHELL_ROOT:-}"
              if [ -z "$root" ]; then
                if [ -f gleam.toml ] && grep -q 'name = "gleshell"' gleam.toml 2>/dev/null; then
                  root="$PWD"
                else
                  echo "gleshell: run from the gleshell repo root, or set GLESHELL_ROOT" >&2
                  exit 1
                fi
              fi
              cd "$root"
              exec gleam run -- "$@"
            '';
          };
        in
        {
          default = gleshell;
          inherit gleshell;
        }
      );

      apps = forEachSystem (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.gleshell}/bin/gleshell";
        };
      });

      devShells = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = devenv.lib.mkShell {
            inherit inputs pkgs;
            modules = [
              {
                devenv.root = builtins.toString ./.;
              }
              ./devenv.nix
            ];
          };
        }
      );

      formatter = forEachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
