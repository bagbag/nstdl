# `nstdl`, baked with one consumer flake's manifest (see the flake-parts module).
{
  lib,
  writers,
  runCommand,
  makeWrapper,
  python3,
  git,
  mkpasswd,
  rage,
  xkcdpass,
  manifest,
  agenix,
}:
let
  tools = [
    git
    mkpasswd
    rage
    xkcdpass
  ];

  script = writers.writePython3 "nstdl" { flakeIgnore = [ "E501" ]; } (builtins.readFile ./nstdl.py);
in
runCommand "nstdl"
  {
    nativeBuildInputs = [ makeWrapper ];
    meta.mainProgram = "nstdl";
    passthru.tests.unit =
      runCommand "nstdl-unit-tests"
        {
          nativeBuildInputs = [ python3 ] ++ tools;
        }
        ''
          export HOME="$TMPDIR"
          git config --global user.email test@example.invalid
          git config --global user.name test
          cp ${./nstdl.py} nstdl.py
          cp ${./test_nstdl.py} test_nstdl.py
          python3 -m unittest -v test_nstdl 2>&1
          touch "$out"
        '';
  }
  ''
    makeWrapper ${script} "$out/bin/nstdl" \
      --prefix PATH : ${lib.makeBinPath tools} \
      --set NSTDL_MANIFEST ${manifest} \
      --set NSTDL_AGENIX ${agenix}
  ''
