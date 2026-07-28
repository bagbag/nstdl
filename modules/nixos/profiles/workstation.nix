{
  config,
  lib,
  pkgs,
  ...
}:
let
  userName = config.nstdl.user.name;
in
{
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

  assertions = [
    {
      assertion = userName != null;
      message = "nstdl workstation requires nstdl.user.name.";
    }
  ];

  networking.networkmanager.enable = true;

  services.xserver.xkb = {
    layout = config.nstdl.locale.keyboard.layout;
    variant = config.nstdl.locale.keyboard.variant;
  };

  users.users = lib.mkIf (userName != null) {
    ${userName}.extraGroups = [
      "networkmanager"
      "video"
      "audio"
    ];
  };

  services = {
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
    pulseaudio.enable = false;
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
    };
    blueman.enable = true;
    fwupd.enable = true;
    flatpak.enable = true;
  };

  hardware = {
    bluetooth = {
      enable = true;
      powerOnBoot = true;
      settings.General.Experimental = true;
    };
    graphics.enable = true;
  };

  security.rtkit.enable = true;
  programs.dconf.enable = true;

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
