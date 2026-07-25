{ inputs }:
{ ... }:
{
  config.nstdl.profiles = {
    nixos.secrets = {
      imports = [
        inputs.ragenix.nixosModules.default
        inputs.agenix-rekey.nixosModules.default
      ];
    };

    darwin.secrets = {
      imports = [
        inputs.ragenix.darwinModules.default
        inputs.agenix-rekey.darwinModules.default
      ];
    };
  };
}
