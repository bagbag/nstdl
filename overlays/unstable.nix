# `pkgs.unstable`, with the host's system and nixpkgs config.
{ inputs }:
_final: prev: {
  unstable = import inputs.nixpkgs-unstable {
    inherit (prev.stdenv.hostPlatform) system;
    inherit (prev) config;
  };
}
