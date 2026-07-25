{ inputs }:
{
  config.nstdl.profiles.home.desktop-apps = {
    imports = [
      inputs.nix-flatpak.homeManagerModules.nix-flatpak
      ../../home-manager/profiles/desktop-apps.nix
    ];
  };
  config.nstdl.profiles.nixos.desktop-apps = ../../nixos/profiles/desktop-apps.nix;
  config.nstdl.profiles.darwin.desktop-apps = ../../darwin/profiles/desktop-apps.nix;
}
