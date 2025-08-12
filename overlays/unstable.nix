{ inputs, ... }:
final: prev: {
  unstable = import inputs.nixpkgs-unstable {
    inherit (final) system;
    config.allowUnfree = final.config.allowUnfree or false;
  };
}
