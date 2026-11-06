# The host's `nstdl`, baked with one host's command table (see
# modules/nixos/commands.nix).
{
  writers,
  runCommand,
  makeWrapper,
  python3,
  commands,
}:
let
  script = writers.writePython3 "nstdl" { flakeIgnore = [ "E501" ]; } (
    builtins.readFile ./nstdl_host.py
  );
in
runCommand "nstdl"
  {
    nativeBuildInputs = [ makeWrapper ];
    meta.mainProgram = "nstdl";
    passthru.tests.unit = runCommand "nstdl-host-unit-tests" { nativeBuildInputs = [ python3 ]; } ''
      cp ${./nstdl_host.py} nstdl_host.py
      cp ${./test_nstdl_host.py} test_nstdl_host.py
      python3 -m unittest -v test_nstdl_host 2>&1
      touch "$out"
    '';
  }
  ''
    makeWrapper ${script} "$out/bin/nstdl" --set NSTDL_COMMANDS ${commands}
  ''
