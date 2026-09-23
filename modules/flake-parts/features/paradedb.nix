{ inputs }:
{ ... }:
{
  # Reuses the exact keyed value flake.nix exports, so a host that pulls in
  # both routes (this profile and a direct `nixosModules.paradedb` import)
  # dedupes instead of colliding. See flake.nix.
  config.nstdl.profiles.nixos.paradedb = inputs.self.nixosModules.paradedb;
}
