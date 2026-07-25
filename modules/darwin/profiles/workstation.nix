{ pkgs, ... }:
{
  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = true;
      upgrade = true;
      cleanup = "zap";
    };
    casks = [ "ghostty" ];
  };

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-color-emoji
    liberation_ttf
    fira-code
    fira-code-symbols
    nerd-fonts.fira-code
    nerd-fonts.droid-sans-mono
  ];
}
