{
  lib,
  nstdlLocale ? null,
  pkgs,
  ...
}:
let
  locale =
    if nstdlLocale == null then
      {
        keyboard = {
          layout = "de";
          variant = "nodeadkeys";
        };
      }
    else
      nstdlLocale;
in
{
  programs.ghostty = {
    enable = true;
    package = if pkgs.stdenv.isLinux then pkgs.ghostty else null;
    enableBashIntegration = true;
    enableZshIntegration = true;
    settings = {
      window-width = 165;
      window-height = 40;
      font-family = "FiraCode Nerd Font Mono";
      font-size = 12;
      font-thicken = true;
      font-thicken-strength = 128;
      theme = "Atom One Dark";
      window-padding-x = 4;
      window-padding-y = 4;
      mouse-hide-while-typing = true;
      scrollback-limit = 10000000;
      background-opacity = 0.9;
      background-blur = false;
      unfocused-split-opacity = 0.9;
      window-vsync = true;
      shell-integration-features = [
        "ssh-env"
        "ssh-terminfo"
      ];
    }
    // lib.optionalAttrs pkgs.stdenv.isDarwin {
      command = "/bin/zsh -l";
      macos-option-as-alt = "left";
      macos-titlebar-style = "tabs";
      quit-after-last-window-closed = true;
    }
    // lib.optionalAttrs pkgs.stdenv.isLinux {
      command = "${pkgs.zsh}/bin/zsh --login";
      gtk-single-instance = false;
    };
  };

  dconf.settings = lib.mkIf pkgs.stdenv.isLinux {
    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
      clock-show-weekday = true;
      clock-show-seconds = true;
      show-battery-percentage = true;
      enable-hot-corners = false;
      font-name = "Noto Sans 12";
      monospace-font-name = "Noto Sans Mono 12";
    };

    "org/gnome/desktop/input-sources".sources = [
      (lib.gvariant.mkTuple [
        "xkb"
        "${locale.keyboard.layout}+${locale.keyboard.variant}"
      ])
    ];

    "org/gnome/desktop/wm/preferences".button-layout = "appmenu:minimize,maximize,close";
  };
}
