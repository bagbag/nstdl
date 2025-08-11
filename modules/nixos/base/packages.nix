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

    inputs.ragenix.packages.${pkgs.system}.default
  ];
}
