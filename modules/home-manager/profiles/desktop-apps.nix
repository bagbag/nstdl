{ lib, pkgs, ... }:
{
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
