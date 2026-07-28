{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    git
    jq
    nh
    nix-tree
    ripgrep
  ];
}
