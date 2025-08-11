{
  config,
  pkgs,
  lib,
  ...
}:
{
  boot.loader.systemd-boot = {
    enable = lib.mkDefault true;
    configurationLimit = lib.mkDefault 10;
  };

  boot.loader.efi.canTouchEfiVariables = lib.mkDefault false;

  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages;

  boot.kernelParams = [
    "zswap.enabled=1"
    "zswap.compressor=zstd"
    "zswap.max_pool_percent=20"
    "zswap.shrinker_enabled=1"
  ];

  time.timeZone = lib.mkDefault "Europe/Berlin";
  i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";
  console.keyMap = lib.mkDefault "de-latin1-nodeadkeys";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  systemd.enableStrictShellChecks = lib.mkDefault true;
}
