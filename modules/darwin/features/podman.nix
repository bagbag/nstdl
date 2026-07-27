{ pkgs, ... }:
{
  environment.systemPackages = [
    pkgs.podman
    pkgs.podman-compose
  ];
}
