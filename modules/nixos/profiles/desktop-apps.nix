{ pkgs, ... }:
{
  programs.firefox = {
    enable = true;
    package = pkgs.firefox-devedition;
  };
  programs.thunderbird.enable = true;
  environment.systemPackages = with pkgs; [
    ffmpeg
    transmission_4-gtk
  ];
}
