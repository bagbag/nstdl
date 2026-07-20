{ inputs, ... }:
final: prev: {
  unstable = import inputs.nixpkgs-unstable {
    inherit (prev.stdenv.hostPlatform) system;
    config.allowUnfree = prev.config.allowUnfree or false;
  };
}
