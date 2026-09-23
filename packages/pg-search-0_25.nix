# pg_search (ParadeDB BM25 search) for PostgreSQL.
#
# nixpkgs carries 0.24.3 while tstdl's development image tracks 0.25.x. Keep
# this in step with the ParadeDB image in tstdl's
# `container/postgres/Containerfile`.
#
# Derived from nixpkgs (pkgs/servers/sql/postgresql/ext/pg_search.nix); drop
# once nixpkgs ships 0.25 together with cargo-pgrx 0.19.
{
  buildPgrxExtension,
  cargo-pgrx_0_19_0,
  fetchFromGitHub,
  fetchurl,
  lib,
  openblas,
  pkg-config,
  postgresql,
  stdenv,
}:

buildPgrxExtension (finalAttrs: {
  pname = "pg_search";
  version = "0.25.9";

  src = fetchFromGitHub {
    owner = "paradedb";
    repo = "paradedb";
    tag = "v${finalAttrs.version}";
    hash = "sha256-FPRsbSjsY4w4I9AuSzOUDIlniTah6tmnOvL46ooX29o=";
  };

  cargoHash = "sha256-K0jAg5A8jr9Ip9BXL8KLdSwPLkgR4Rp9grlWfRcDuAI=";

  inherit postgresql;

  preConfigure =
    let
      # LINDERA_CACHE stops the Lindera crates' build.rs from downloading
      # dictionaries, which the sandbox forbids. Read from paradedb v0.25.9's
      # Cargo.lock; bump alongside the version.
      linderaVersion = "1.5.1";

      dict = language: filename: hash: {
        inherit filename language;
        source = fetchurl {
          url = "https://lindera.dev/${filename}";
          inherit hash;
        };
      };

      dictionaries = {
        lindera-ko-dic =
          dict "Korean" "mecab-ko-dic-2.1.1-20180720.tar.gz"
            "sha256-cCztIcYWfp2a68Z0q17lSvWNREOXXylA030FZ8AgWRo=";
        lindera-cc-cedict =
          dict "Chinese" "CC-CEDICT-MeCab-0.1.0-20200409.tar.gz"
            "sha256-7Tz54+yKgGR/DseD3Ana1DuMytLplPXqtv8TpB0JFsg=";
        lindera-ipadic =
          dict "Japanese" "mecab-ipadic-2.7.0-20250920.tar.gz"
            "sha256-p7qfZF/+cJTlauHEqB0QDfj7seKLvheSYi6XKOFi2z0=";
      };
    in
    ''
      export LINDERA_CACHE=$TMPDIR/lindera-cache
      mkdir -p $LINDERA_CACHE/${linderaVersion}
      ${lib.concatMapStringsSep "\n" (dict: ''
        echo "Copying ${dict.language} dictionary to Lindera cache"
        cp ${dict.source} $LINDERA_CACHE/${linderaVersion}/${dict.filename}
      '') (lib.attrValues dictionaries)}
    '';

  # paradedb 0.25.9 pins `pgrx = "=0.19.0"` in its workspace Cargo.toml.
  cargo-pgrx = cargo-pgrx_0_19_0;

  cargoPgrxFlags = [
    "--package"
    "pg_search"
  ];

  nativeBuildInputs = [ pkg-config ];

  # 0.25.9 links its vector paths against BLAS; without this the extension
  # compiles and then fails at link with `cannot find -lopenblas`.
  buildInputs = [ openblas ];

  # ...and `buildInputs` alone only gets it past the link. Since 1.90 rustc
  # links x86_64-linux with its bundled rust-lld, which bypasses the ld
  # wrapper, so no RUNPATH is written at all (rust-lang/rust#162781). The
  # rustc here is fenix's upstream build (modules/nixos/features/paradedb.nix).
  # `libopenblas.so.0` is then unresolvable at load time, and since the module
  # preloads pg_search, postgres refuses to start. Opting out of the bundled
  # linker routes the link through the wrapper, which derives the RPATH from
  # `buildInputs` — every linked library, not only openblas.
  #
  # openblas is not optional: pg_search/Cargo.toml pulls `superkmeans` with
  # `features = ["openblas"]` for `cfg(not(target_os = "macos"))`.
  #
  # Retire once rustc's self-contained linker writes the RUNPATH itself;
  # `postFixup` fails the build whenever it goes missing, whatever the cause.
  # x86_64 only: no other target links through rust-lld by default, and stable
  # rustc rejects `link-self-contained=-linker` elsewhere as unstable.
  # `buildPgrxExtension` sets RUSTFLAGS on Darwin only, so claiming it is safe.
  env = lib.optionalAttrs (stdenv.hostPlatform.rust.rustcTargetSpec == "x86_64-unknown-linux-gnu") {
    RUSTFLAGS = "-C linker-features=-lld -C link-self-contained=-linker";
  };

  postFixup = lib.optionalString stdenv.hostPlatform.isElf ''
    if ! patchelf --print-rpath "$out/lib/pg_search.so" | tr ':' '\n' | grep -qxF '${lib.getLib openblas}/lib'; then
      echo "pg_search.so has no RUNPATH entry for openblas; postgres could not preload it" >&2
      exit 1
    fi
  '';

  # pgrx tests try to install the extension into the postgresql store path.
  doCheck = false;

  meta = {
    description = "Transactional Elasticsearch alternative as a PostgreSQL extension";
    homepage = "https://paradedb.com";
    changelog = "https://github.com/paradedb/paradedb/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.agpl3Only;
    broken = lib.versionOlder postgresql.version "15";
    platforms = postgresql.meta.platforms;
  };
})
