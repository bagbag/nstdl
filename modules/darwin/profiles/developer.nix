{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    git
    jq
    nix-tree
    ripgrep
  ];
}
