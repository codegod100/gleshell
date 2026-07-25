{ pkgs, ... }:

{
  packages = with pkgs; [
    gleam
    beamPackages.erlang
    rebar3
  ];

  enterShell = ''
    echo "gleshell devenv — gleam run / gleam test / gleam run -- -c 'ls | first 3'"
  '';
}
