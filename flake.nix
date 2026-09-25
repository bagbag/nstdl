{
  description = "nstdl - opinionated Nix infrastructure and workstation profiles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-flatpak = {
      url = "github:gmodena/nix-flatpak/?ref=v0.7.0";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix-rekey = {
      url = "github:oddlama/agenix-rekey";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };

    # Temporary PR until main is fixed, then return to upstream main.
    ragenix = {
      url = "github:yaxitech/ragenix/pull/168/head";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Rust toolchain for the pgrx-based PostgreSQL extensions. pgrx 0.19
    # declares rust-version 1.96, which nixpkgs release branches lag behind, and
    # a consumer's `nixpkgs.follows` drags this flake's nixpkgs down to theirs —
    # so the toolchain cannot come from nixpkgs. Detail in paradedb.nix.
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sleepless = {
      url = "github:bagbag/Sleepless";
      flake = false;
    };
  };

  outputs =
    inputs@{ ... }:
    let
      lib = inputs.nixpkgs.lib;
    in
    {
      flakeModules.default = import ./modules/flake-parts/default.nix { inherit inputs; };

      # Individually consumable, for repositories that are not themselves built
      # on the flake-parts module above, e.g. an application's own NixOS VM
      # test. A NixOS module rather than a package output: the feature builds
      # the extension against `config.services.postgresql.package`, and a bare
      # package would have to guess a PostgreSQL version.
      #
      # Keyed so this same value can be imported both directly and, via
      # `nstdl.profiles.nixos.paradedb` (modules/flake-parts/features/paradedb.nix),
      # through the flake-parts module, without the two routes colliding.
      nixosModules.paradedb = {
        key = "nstdl#nixosModules.paradedb";
        imports = [ (lib.modules.importApply ./modules/nixos/features/paradedb.nix { inherit inputs; }) ];
      };

      # Same reason: an application's VM test can run the host's object
      # storage. A plain path, so it already dedupes like any other module.
      nixosModules.garage = ./modules/nixos/features/garage.nix;

      checks = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: {
        garage = import ./tests/garage.nix {
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          module = ./modules/nixos/features/garage.nix;
        };
      });
    };
}
