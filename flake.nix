{
  description = "nstdl - Nix Standard Infrastructure Library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    snowfall-lib = {
      url = "github:snowfallorg/lib";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    ragenix = {
      url = "github:yaxitech/ragenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    base = ./modules/nixos/base;
    mkFlake = (./lib/mk-flake.nix).mkFlake;

    # NixOS modules provided by this flake
    nixosModules = {
      age = ./modules/nixos/age;
      disko = ./modules/nixos/disko/disko.nix;
      mariadb-managed = ./modules/nixos/mariadb-managed;
      postgresql-backup = ./modules/nixos/postgresql-backup;
      postgresql-managed = ./modules/nixos/postgresql-managed;
      proxmox-backup = ./modules/nixos/proxmox-backup;
    };

    overlays = {
      unstable = import ./overlays/unstable.nix { inherit inputs; };
    };
  };
}
