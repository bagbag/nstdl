# cargo-pgrx 0.19.0.
#
# nixpkgs stops at 0.18.1, but ParadeDB pins `pgrx = "=0.19.0"` from pg_search
# 0.25.0 onwards. Mirrors the nixpkgs derivation
# (pkgs/development/tools/rust/cargo-pgrx); drop once nixpkgs carries 0.19.
{
  fetchCrate,
  lib,
  openssl,
  pkg-config,
  rustPlatform,
}:

rustPlatform.buildRustPackage rec {
  pname = "cargo-pgrx";
  version = "0.19.0";

  src = fetchCrate {
    inherit pname version;
    hash = "sha256-1OTE+mPtR9vaJhVGvq9X3fNd1nRoedoABUaVGQvFwNU=";
  };

  cargoHash = "sha256-dTfbgc6pGLP3s9y3zfIk97XUkPiLngdIoilIX7UM4W8=";

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];

  # On x86_64-linux, rustc links through its bundled rust-lld by default,
  # which bypasses the ld wrapper and writes no RUNPATH (rust-lang/rust#162781,
  # same cause as pg_search's). The linked binary then has no path to
  # libssl.so.3 and dies on load — both under `cargo test`, which spawns it,
  # and later when buildPgrxExtension invokes it. Stated explicitly so it
  # holds whichever toolchain builds this.
  env.RUSTFLAGS = "-C link-arg=-Wl,-rpath,${lib.makeLibraryPath [ openssl ]}";

  preCheck = ''
    export PGRX_HOME=$(mktemp -d)
  '';

  checkFlags = [
    # Requires pgrx to be initialized with `cargo pgrx init`.
    "--skip=object_utils::tests::parses_managed_postmasters"

    # Read fixtures the crates.io tarball does not ship; they fail with
    # `fixture exists: Io(NotFound)` regardless of toolchain.
    "--skip=command::upgrade::tests::find_package_manifest_in_workspace"
    "--skip=command::upgrade::tests::process_workspace_manifest"
    "--skip=command::upgrade::tests::process_workspace_package_manifest"
  ];

  meta = {
    description = "Build Postgres Extensions with Rust";
    homepage = "https://github.com/pgcentralfoundation/pgrx";
    changelog = "https://github.com/pgcentralfoundation/pgrx/releases/tag/v${version}";
    license = lib.licenses.mit;
    mainProgram = "cargo-pgrx";
  };
}
