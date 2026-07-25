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

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ self, ... }:
    {
      flakeModules.default = import ./modules/flake-parts/default.nix { inherit inputs; };

      nixosModules = {
        core = import ./modules/nixos/profiles/core.nix;
        server = {
          imports = [
            ./modules/nixos/profiles/core.nix
            ./modules/nixos/profiles/server.nix
          ];
        };
        workstation = {
          imports = [
            ./modules/nixos/profiles/core.nix
            ./modules/nixos/profiles/workstation.nix
          ];
        };
        developer = import ./modules/nixos/profiles/developer.nix;
        desktop-apps = import ./modules/nixos/profiles/desktop-apps.nix;
        accounts = import ./modules/nixos/profiles/accounts.nix;
        postgresql = import ./modules/nixos/features/postgresql.nix;
        proxmox-backup = import ./modules/nixos/features/proxmox-backup.nix;
        secrets = {
          imports = [
            inputs.ragenix.nixosModules.default
            inputs.agenix-rekey.nixosModules.default
          ];
        };
      };

      homeModules = {
        developer = {
          imports = [
            inputs.nix-index-database.homeModules.nix-index
            ./modules/home-manager/profiles/developer.nix
          ];
        };
        workstation = import ./modules/home-manager/profiles/workstation.nix;
        desktop-apps = {
          imports = [
            inputs.nix-flatpak.homeManagerModules.nix-flatpak
            ./modules/home-manager/profiles/desktop-apps.nix
          ];
        };
      };

      darwinModules = {
        core = import ./modules/darwin/profiles/core.nix;
        workstation = {
          imports = [
            ./modules/darwin/profiles/core.nix
            ./modules/darwin/profiles/workstation.nix
          ];
        };
        developer = import ./modules/darwin/profiles/developer.nix;
        desktop-apps = import ./modules/darwin/profiles/desktop-apps.nix;
        secrets = {
          imports = [
            inputs.ragenix.darwinModules.default
            inputs.agenix-rekey.darwinModules.default
          ];
        };
      };

    };
}
