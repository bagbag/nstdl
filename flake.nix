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

    ragenix = {
      url = "github:yaxitech/ragenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Rust toolchain for the pgrx-based PostgreSQL extensions. pgrx 0.19
    # declares rust-version 1.96, which nixpkgs release branches lag behind, and
    # a consumer's `nixpkgs.follows` drags this flake's nixpkgs down to theirs —
    # so the toolchain cannot come from nixpkgs. Expressed as a version rather
    # than as a nixpkgs revision that happens to carry one.
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
    {
      flakeModules.default = import ./modules/flake-parts/default.nix { inherit inputs; };

    };
}
