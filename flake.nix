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
          inherit (pkgs) lib;

          gleamToml = lib.importTOML ./gleam.toml;
          manifestToml = lib.importTOML ./manifest.toml;

          hexPackages = builtins.filter (p: p.source == "hex") manifestToml.packages;

          packagesTOML = lib.concatStringsSep "\n" (
            [ "[packages]" ] ++ map (p: "${p.name} = \"${p.version}\"") hexPackages
          );

          # Self-contained store package: compiles to Erlang shipment, wraps with
          # store-path Erlang. No source checkout / GLESHELL_ROOT required at runtime.
          gleshell = pkgs.stdenv.mkDerivation {
            pname = "gleshell";
            version = gleamToml.version;

            src = lib.cleanSourceWith {
              src = ./.;
              filter =
                path: type:
                let
                  base = baseNameOf path;
                in
                lib.cleanSourceFilter path type
                && base != "build"
                && base != "result"
                && base != ".devenv"
                && base != ".direnv"
                && base != "erl_crash.dump"
                # Root escript is a regular file; keep the src/gleshell/ directory.
                && !(type == "regular" && base == "gleshell")
                && !(lib.hasSuffix ".escript" base);
            };

            nativeBuildInputs = [
              pkgs.gleam
              pkgs.beamPackages.erlang
              pkgs.rebar3
              pkgs.beamPackages.hex
              pkgs.rsync
            ];

            configurePhase = ''
              runHook preConfigure

              mkdir -p build/packages
              cat <<EOF > build/packages/packages.toml
              ${packagesTOML}
              EOF

              # Vendor Hex deps so the pure Nix build never hits the network.
              ${lib.concatMapStringsSep "\n" (p: ''
                rsync --chmod=Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r,Fo=r -r ${
                  pkgs.fetchHex {
                    pkg = p.name;
                    version = p.version;
                    sha256 = p.outer_checksum;
                  }
                }/* build/packages/${p.name}/
              '') hexPackages}

              runHook postConfigure
            '';

            buildPhase = ''
              runHook preBuild
              export REBAR_CACHE_DIR="$TMP/.rebar-cache"
              gleam export erlang-shipment
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p $out/{bin,lib/gleshell}
              rsync --exclude=entrypoint.sh --exclude=entrypoint.ps1 \
                -r build/erlang-shipment/* $out/lib/gleshell/

              # Bake -pa paths at install time (each ebin needs its own -pa).
              ebin_args=()
              for d in $out/lib/gleshell/*/ebin; do
                ebin_args+=(-pa "$d")
              done

              # Runtime wrapper: fixed store paths, works from any cwd.
              # +Bc: Ctrl+C cancels the line; do not open the Erlang BREAK menu.
              {
                echo "#!${pkgs.runtimeShell}"
                echo "set -eu"
                echo 'export ERL_AFLAGS="+Bc ''${ERL_AFLAGS:-}"'
                echo "exec ${pkgs.beamPackages.erlang}/bin/erl ''${ebin_args[*]} -eval \"gleshell@@main:run(gleshell)\" -noshell -extra \"\$@\""
              } > $out/bin/gle
              chmod +x $out/bin/gle
              ln -s gle $out/bin/gleshell

              runHook postInstall
            '';

            meta = {
              description = gleamToml.description;
              mainProgram = "gle";
              license = lib.licenses.asl20;
            };
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
          program = "${self.packages.${system}.gleshell}/bin/gle";
        };
      });

      devShells = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          # --no-pure-eval (or direnv) is required so devenv can resolve
          # devenv.root from $PWD; pure eval would point ./. at the store.
          default = devenv.lib.mkShell {
            inherit inputs pkgs;
            modules = [ ./devenv.nix ];
          };
        }
      );

      formatter = forEachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
