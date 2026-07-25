{
  description = "A demo flake using nstdl";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    nstdl = {
      url = "github:bagbag/nstdl";
      # For local nstdl development:
      # url = "path:..";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.nstdl.flakeModules.default ];

      nstdl = {
        accounts.people.deploy.sshKeys = [ "ssh-ed25519 AAAA... deploy@example.com" ];
        hosts.demo-server = {
          platform = "nixos";
          system = "x86_64-linux";
          role = "server";
          features = [ "developer" ];
          systemStateVersion = "26.05";
          accounts = {
            primary = "deploy";
            users.deploy.people = [ "deploy" ];
            root = {
              enable = true;
              sshPeople = [ "deploy" ];
            };
          };
          extraModules = [ ./systems/x86_64-linux/demo-server/default.nix ];
        };
      };
    };
}
