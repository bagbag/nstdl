{ inputs, ... }:
final: prev: {
  unstable = import inputs.nixpkgs-unstable {
    inherit (prev) system config; # Inherit the configuration from the stable package set
  };
}
