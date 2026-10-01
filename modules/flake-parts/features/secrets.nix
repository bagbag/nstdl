{ inputs }:
{ ... }:
{
  config.nstdl.profiles = {
    nixos.secrets = {
      imports = [
        inputs.agenix.nixosModules.default
        inputs.agenix-rekey.nixosModules.default
      ];
    };

    darwin.secrets = {
      imports = [
        inputs.agenix.darwinModules.default
        inputs.agenix-rekey.darwinModules.default
      ];
    };
  };
}
