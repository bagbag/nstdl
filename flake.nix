{
  description = "nstdl - Nix Standard Infrastructure Library";

  # Declare the names of all inputs the flake requires.
  # The consumer flake is responsible for providing the actual sources for these inputs.
  inputs = {
    nixpkgs = { };
    nixpkgs-unstable = { };
    snowfall-lib = { };
    disko = { };
    ragenix = { };
    home-manager = { };
    nix-index-database = { };
    deploy-rs = { };
  };

  outputs =
    { self, ... }@inputs:
    let
      nixosModules = {
        age = ./modules/nixos/age;
        disko = ./modules/nixos/disko;
        mariadb-managed = ./modules/nixos/mariadb-managed;
        postgresql-backup = ./modules/nixos/postgresql-backup;
        postgresql-managed = ./modules/nixos/postgresql-managed;
        proxmox-backup = ./modules/nixos/proxmox-backup;
      };
    in
    {
      mkFlake =
        ((import ./lib/mk-flake.nix) {
          lib = inputs.nixpkgs.lib;
          inherit inputs;
          # Pass your library's own modules to the helper's context
          selfNixosModules = inputs.nixpkgs.lib.attrValues nixosModules;
        }).mkFlake;

      base = ./modules/nixos/base;

      # Expose the modules for users who might want to use them individually
      inherit nixosModules;

      overlays = {
        unstable = import ./overlays/unstable.nix { inherit inputs; };
      };
    };
}
