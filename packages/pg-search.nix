# pg_search (ParadeDB BM25 search) for PostgreSQL.
#
# Keep this in step with the ParadeDB image in tstdl's
# `container/postgres/Containerfile`; nixpkgs lags behind it.
#
# Derived from nixpkgs (pkgs/servers/sql/postgresql/ext/pg_search.nix); drop
# once the nixpkgs release branches hosts follow carry this version.
{
  buildPgrxExtension,
  cargo-pgrx,
  fetchFromGitHub,
  fetchurl,
  lib,
  openblas,
  pkg-config,
  postgresql,
  stdenv,
}:

let
  # paradedb's exact `pgrx` pin (workspace Cargo.toml); cargo-pgrx must match.
  pgrxVersion = "0.19.3";
in
assert lib.assertMsg (cargo-pgrx.version == pgrxVersion)
  "pg_search needs cargo-pgrx ${pgrxVersion}, got ${cargo-pgrx.version}: bump pg_search to a release pinning it, or provide a matching cargo-pgrx.";

buildPgrxExtension (finalAttrs: {
  pname = "pg_search";
  version = "0.26.5";

  src = fetchFromGitHub {
    owner = "paradedb";
    repo = "paradedb";
    tag = "v${finalAttrs.version}";
    hash = "sha256-yuHgxVWiBejXArBmVnldIIlQsGk4tIi1IeLvAp5hbwM=";
  };

  cargoHash = "sha256-LfGJyWirZNAFaXfm2tT1I3m+Ufk5wW+p9on/quqew3M=";

  inherit postgresql;

  preConfigure =
    let
      # Pre-filled so Lindera's build.rs doesn't download (sandbox). Layout:
      # `<cache>/<crate version>-fmt<DICTIONARY_FORMAT_VERSION>/<file>`; bump
      # with the version (Cargo.lock, lindera-dictionary's metadata.rs).
      linderaCache = "6.2.0-fmt2";

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
      export LINDERA_BUILD_DICTIONARY_CACHE_DIR=$TMPDIR/lindera-cache
      mkdir -p $LINDERA_BUILD_DICTIONARY_CACHE_DIR/${linderaCache}
      ${lib.concatMapStringsSep "\n" (dict: ''
        echo "Copying ${dict.language} dictionary to Lindera cache"
        cp ${dict.source} $LINDERA_BUILD_DICTIONARY_CACHE_DIR/${linderaCache}/${dict.filename}
      '') (lib.attrValues dictionaries)}
    '';

  inherit cargo-pgrx;

  # Upstream links Linux with lld, bypassing the ld wrapper that writes the
  # RUNPATH `postFixup` checks.
  postPatch = ''
    substituteInPlace .cargo/config.toml \
      --replace-fail 'rustflags = ["-Clink-arg=-fuse-ld=lld"]' ""
  '';

  cargoPgrxFlags = [
    "--package"
    "pg_search"
  ];

  nativeBuildInputs = [ pkg-config ];

  # `superkmeans` (openblas feature, off macOS) links `-lopenblas`; 0.26.5
  # calls none of it, so `--as-needed` drops it again.
  buildInputs = lib.optionals (!stdenv.hostPlatform.isDarwin) [ openblas ];

  # The library is preloaded: one unresolvable dependency keeps postgres from
  # starting, so fail the build instead.
  postFixup = lib.optionalString stdenv.hostPlatform.isElf ''
    so=$out/lib/pg_search.so
    runpath=$(patchelf --print-rpath "$so")
    for needed in $(patchelf --print-needed "$so"); do
      found=
      for dir in ''${runpath//:/ }; do
        if [ -e "$dir/$needed" ]; then found=1; break; fi
      done
      if [ -z "$found" ]; then
        echo "pg_search.so: $needed is not in its RUNPATH; postgres could not preload it" >&2
        exit 1
      fi
    done
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
