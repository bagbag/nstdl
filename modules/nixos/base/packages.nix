{ pkgs, inputs, ... }:
{
  environment.systemPackages = with pkgs; [
    git
    wget
    curl
    bind
    inetutils
    tcpdump
    ipcalc

    ragenix # in case a future flake update breaks the package in nixpkgs: inputs.ragenix.packages.${pkgs.system}.default
  ];
}
