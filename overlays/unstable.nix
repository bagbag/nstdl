{ inputs, ... }:
final: prev: {
  unstable = import inputs.nixpkgs-unstable {
    inherit (prev) system;
    config.allowUnfree = prev.config.allowUnfree or false;
  };
}
