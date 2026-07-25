{
  config.nstdl.profiles = {
    nixos = {
      server = ../../nixos/profiles/core.nix;
      workstation = ../../nixos/profiles/core.nix;
    };

    darwin.workstation = ../../darwin/profiles/core.nix;
  };
}
