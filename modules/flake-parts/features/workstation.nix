{
  config.nstdl.profiles = {
    nixos.workstation = {
      imports = [ ../../nixos/profiles/workstation.nix ];
    };

    darwin.workstation = {
      imports = [ ../../darwin/profiles/workstation.nix ];
    };

    home.workstation = ../../home-manager/profiles/workstation.nix;
  };
}
