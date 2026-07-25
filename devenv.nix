{ pkgs, ... }:

{
  packages = with pkgs; [
    gleam
    beamPackages.erlang
    rebar3
  ];

  enterShell = ''
    # +Bc: Ctrl+C cancels the line instead of the Erlang BREAK menu (abort).
    # gleshell also re-execs with +Bc if this is unset; exporting avoids the hop.
    export ERL_AFLAGS="+Bc ''${ERL_AFLAGS:-}"
    echo "gleshell devenv — gleam run / gleam test / gleam run -- -c 'ls | first 3'"
  '';
}
