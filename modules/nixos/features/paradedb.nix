{ inputs }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.nstdl.paradedb;

  # Release branches lack pgrx 0.19's rustc and ParadeDB's exact cargo-pgrx, so
  # only these build tools come from unstable. The extension itself builds in
  # the host's package set: postgres loads it next to the host's glibc.
  unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};

  # Scoped to this evaluation rather than `nixpkgs.overlays`, which would put
  # every Rust package on the host through a different compiler.
  # `buildPgrxExtension` picks it up because it is `callPackage`d from this
  # same set.
  rustPkgs = pkgs.extend (
    _: prev: {
      rustPlatform = prev.makeRustPlatform { inherit (unstable) cargo rustc; };
    }
  );

  pg_search = rustPkgs.callPackage ../../../packages/pg-search-0_26.nix {
    inherit (unstable) cargo-pgrx;
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
      # From 0.25.0 pg_search's control metadata requires pgvector.
      extensions = ps: [
        ps.pgvector
        pg_search
      ];

      # pg_search writes its index from a background worker; unpreloaded,
      # creating a BM25 index hangs or drops the connection. No `mkDefault`:
      # the option merges by concatenation, so a default would be discarded as
      # soon as anything else preloads a library.
      settings.shared_preload_libraries = [ "pg_search" ];

      # The unit denies `@resources`, and preloading pg_search calls `mbind`
      # from it: without this, postgres is killed with SIGSYS at startup. Only
      # the one call is re-allowed, as nixpkgs does for citus.
      systemCallFilter.mbind = true;
    };
  };
}
