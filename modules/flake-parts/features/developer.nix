{ inputs }:
{ ... }:
{
  config.nstdl.profiles = {
    nixos.developer = ../../nixos/profiles/developer.nix;
    darwin.developer = ../../darwin/profiles/developer.nix;
    home.developer = {
      imports = [
        inputs.nix-index-database.homeModules.nix-index
        ../../home-manager/profiles/developer.nix
      ];
    };
  };
}
