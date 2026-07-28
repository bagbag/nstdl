{ lib, pkgs, ... }:
{
  home.sessionVariables = lib.mkIf pkgs.stdenv.isLinux {
    NIXOS_OZONE_WL = "1";
  };

  programs.chromium = lib.mkIf pkgs.stdenv.isLinux {
    enable = true;
    package = pkgs.ungoogled-chromium;
    extensions = [
      { id = "cjpalhdlnbpafiamejdnhcphjbkeiagm"; }
      { id = "pkehgijcmpdhfbdbbnkijodmdjhbjlgp"; }
    ];
  };

  programs.mpv = {
    enable = true;
    package = pkgs.mpv.override {
      scripts = with pkgs.mpvScripts; [ uosc ];
      mpv-unwrapped = pkgs.mpv-unwrapped.override {
        waylandSupport = pkgs.stdenv.isLinux;
      };
    };
    config = {
      profile = "high-quality";
      ytdl-format = "bestvideo+bestaudio";
    };
  };

  services.flatpak = lib.mkIf pkgs.stdenv.isLinux {
    enable = true;
    packages = [ "com.spotify.Client" ];
    update.auto = {
      enable = true;
      onCalendar = "daily";
    };
  };
}
