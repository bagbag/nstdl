{ inputs }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.nstdl.paradedb;

  # pgrx 0.19 declares rust-version 1.96 and errors out below it. The toolchain
  # cannot come from nixpkgs: a consumer's `nixpkgs.follows` pulls this flake's
  # nixpkgs down to theirs, and release branches lag. Only cargo and rustc are
  # taken, so nothing else on the host changes compiler.
  fenixPkgs = inputs.fenix.packages.${pkgs.stdenv.hostPlatform.system};
  rustToolchain = fenixPkgs.combine [
    fenixPkgs.stable.cargo
    fenixPkgs.stable.rustc
  ];

  # Scoped to this evaluation rather than `nixpkgs.overlays`, which would put
  # every Rust package on the host through a different compiler. Only
  # derivations that consume `rustPlatform` are affected — here, cargo-pgrx and
  # the extension — and `buildPgrxExtension` picks it up because it is
  # `callPackage`d from this same set.
  rustPkgs = pkgs.extend (
    _: prev: {
      rustPlatform = prev.makeRustPlatform {
        cargo = rustToolchain;
        rustc = rustToolchain;
      };
    }
  );

  cargo-pgrx_0_19_0 = rustPkgs.callPackage ../../../packages/cargo-pgrx-0_19_0.nix { };

  pg_search = rustPkgs.callPackage ../../../packages/pg-search-0_25.nix {
    inherit cargo-pgrx_0_19_0;
    # Built against the host's own PostgreSQL, not the one in `rustPkgs`.
    postgresql = config.services.postgresql.package;
  };
in
{
  options.services.nstdl.paradedb = {
    enable = lib.mkEnableOption ''
      ParadeDB `pg_search` (BM25 full-text search).

      Tracks the version in tstdl's development image rather than the older
      one in nixpkgs, so development and production run the same ParadeDB.

      Makes the extension available and preloads it. Creating it in a database
      is `services.nstdl.postgresql.databases.<name>.extensions`
    '';
  };

  config = lib.mkIf cfg.enable {
    services.postgresql = {
      # From 0.25.0 pg_search's control metadata requires pgvector, and
      # `vector` must exist before `pg_search` is created.
      extensions = ps: [
        ps.pgvector
        pg_search
      ];

      # pg_search writes its index from a background worker; unpreloaded,
      # creating a BM25 index hangs or drops the connection. No `mkDefault`:
      # the option merges by concatenation, so a default would be discarded as
      # soon as anything else preloads a library.
      settings.shared_preload_libraries = [ "pg_search" ];
    };
  };
}
