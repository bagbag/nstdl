{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nstdl;
in
{
  options.nstdl = {
    hostName = lib.mkOption {
      type = lib.types.str;
      description = "Host name managed by the nstdl profile.";
    };

    domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional DNS domain managed by the nstdl profile.";
    };

    virtualization = lib.mkOption {
      type = lib.types.enum [
        "none"
        "qemu"
        "vmware"
      ];
      default = "none";
      description = "Virtualization guest environment whose agent nstdl enables.";
    };

    user = {
      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Primary interactive user. A profile never creates one by default.";
      };

      authorizedKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "SSH public keys for the primary interactive user.";
      };

      hashedPasswordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional hashed-password file for the primary interactive user.";
      };
    };
  };

  config = {
    programs.zsh.enable = true;
    environment.shells = [ pkgs.nushell ];

    nixpkgs.config.allowUnfree = true;

    nix = {
      package = pkgs.lix;
      settings.experimental-features = [
        "nix-command"
        "flakes"
      ];
      settings = {
        substituters = [ "https://nix-community.cachix.org" ];
        trusted-public-keys = [
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        ];
      };

      gc = {
        automatic = lib.mkDefault true;
        persistent = lib.mkDefault true;
        dates = lib.mkDefault "05:00";
        options = lib.mkDefault "--delete-older-than 14d";
        randomizedDelaySec = lib.mkDefault "25m";
      };

      optimise = {
        automatic = lib.mkDefault true;
        persistent = lib.mkDefault true;
        dates = lib.mkDefault [ "06:00" ];
        randomizedDelaySec = lib.mkDefault "25m";
      };
    };

    environment.systemPackages = with pkgs; [
      bind
      curl
      ghostty.terminfo
      inetutils
      ipcalc
      tcpdump
      wget
    ];

    networking.hostName = cfg.hostName;
    networking.domain = lib.mkIf (cfg.domain != null) cfg.domain;
    networking.nftables.enable = lib.mkDefault true;
    networking.firewall = {
      enable = lib.mkDefault true;
      allowPing = lib.mkDefault true;
    };

    boot.loader.systemd-boot.enable = lib.mkDefault true;
    boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
    zramSwap.enable = lib.mkDefault true;

    services.qemuGuest.enable = cfg.virtualization == "qemu";
    virtualisation.vmware.guest.enable = cfg.virtualization == "vmware";

    time.timeZone = lib.mkDefault "Europe/Berlin";
    i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";
    console.keyMap = lib.mkDefault "de-latin1-nodeadkeys";

    systemd.enableStrictShellChecks = true;

  };
}
