{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.nstdl.paradedb;

  cargo-pgrx_0_19_0 = pkgs.callPackage ../../../packages/cargo-pgrx-0_19_0.nix { };

  # Built against the host's own PostgreSQL, not a pinned one.
  pgPkgs = config.services.postgresql.package.pkgs;

  pg_search = pgPkgs.callPackage ../../../packages/pg-search-0_25.nix {
    inherit cargo-pgrx_0_19_0;
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
