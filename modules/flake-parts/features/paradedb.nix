{ inputs }:
{ ... }:
{
  config.nstdl.profiles.nixos.paradedb = import ../../nixos/features/paradedb.nix { inherit inputs; };
}
