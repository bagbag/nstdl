{ lib, config, ... }:
{
  nix.gc = {
    automatic = true;
    persistent = true;
    dates = "05:00";
    options = "--delete-older-than 14d";
    randomizedDelaySec = "25m";
  };

  nix.optimise = {
    automatic = true;
    persistent = true;
    dates = [ "06:00" ];
    randomizedDelaySec = "25m";
  };
}
