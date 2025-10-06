{
  description = "A demo flake using nstdl's mkFlake helper";

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

    nstdl = {
      url = "github:bagbag/nstdl";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixpkgs-unstable.follows = "nixpkgs-unstable";
      inputs.snowfall-lib.follows = "snowfall-lib";
      inputs.disko.follows = "disko";
      inputs.ragenix.follows = "ragenix";
      inputs.home-manager.follows = "home-manager";
      inputs.nix-index-database.follows = "nix-index-database";
      inputs.deploy-rs.follows = "deploy-rs";
    };
  };

  outputs =
    { self, ... }@inputs:
    let
      # Define host-specific data centrally. The mkFlake helper injects this
      # into each host's configuration as `config.nstdl.hostConfig`.
      # The host key ("demo-server") must match a host directory name found by
      # snowfall-lib (e.g., `systems/x86_64-linux/demo-server`).
      hosts = {
        "demo-server" = {
          environment = "cloud";
          virtualisation = "qemu";
          domain = "example.com";
          interface = "eth0";
          ipv4 = "10.0.0.10/24";
          ipv6 = "fd00::10/64";
          gateway4 = "10.0.0.1";
          gateway6 = "fd00::1";
        };
      };
    in
    # Use the nstdl mkFlake helper to reduce boilerplate.
    inputs.nstdl.mkFlake {
      inherit self inputs hosts;
      src = ./.; # The root of our flake, which snowfall-lib scans.
    };
}
