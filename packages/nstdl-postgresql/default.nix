# Built per host against the server's own PostgreSQL package, so dumps and
# restores use the server's major version.
{
  lib,
  writers,
  runCommand,
  makeWrapper,
  python3,
  postgresql,
  util-linux,
}:
let
  script = writers.writePython3 "nstdl-postgresql" { flakeIgnore = [ "E501" ]; } (
    builtins.readFile ./nstdl_postgresql.py
  );
in
runCommand "nstdl-postgresql"
  {
    nativeBuildInputs = [ makeWrapper ];
    meta.mainProgram = "nstdl-postgresql";
    passthru.tests.unit =
      runCommand "nstdl-postgresql-unit-tests"
        {
          nativeBuildInputs = [
            python3
            postgresql
          ];
        }
        ''
          cp ${./nstdl_postgresql.py} nstdl_postgresql.py
          cp ${./test_nstdl_postgresql.py} test_nstdl_postgresql.py
          python3 -m unittest -v test_nstdl_postgresql 2>&1
          touch "$out"
        '';
  }
  ''
    makeWrapper ${script} "$out/bin/nstdl-postgresql" \
      --prefix PATH : ${
        lib.makeBinPath [
          postgresql
          util-linux
        ]
      }
  ''
