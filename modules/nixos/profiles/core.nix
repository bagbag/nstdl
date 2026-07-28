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

    locale = {
      language = lib.mkOption {
        type = lib.types.str;
        default = "en_US.UTF-8";
        description = "Locale used for messages and the default language.";
      };
      format = lib.mkOption {
        type = lib.types.str;
        default = "de_DE.UTF-8";
        description = "Locale used for regional formatting such as dates, numbers, and paper size.";
      };
      consoleKeyMap = lib.mkOption {
        type = lib.types.str;
        default = "de-latin1-nodeadkeys";
        description = "Linux virtual-console keymap.";
      };
      keyboard = {
        layout = lib.mkOption {
          type = lib.types.str;
          default = "de";
          description = "Graphical keyboard layout for NixOS workstations.";
        };
        variant = lib.mkOption {
          type = lib.types.str;
          default = "nodeadkeys";
          description = "Graphical keyboard variant for NixOS workstations.";
        };
      };
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
        automatic = lib.mkDefault false;
        persistent = lib.mkDefault true;
      };

      optimise = {
        automatic = lib.mkDefault false;
        persistent = lib.mkDefault true;
      };
    };

    programs.nh = {
      enable = true;
      clean = {
        enable = lib.mkDefault true;
        dates = lib.mkDefault "08:00";
        extraArgs = lib.mkDefault "--keep 5 --keep-since 14d --optimise";
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

    boot.loader.systemd-boot = {
      enable = lib.mkDefault true;
      configurationLimit = lib.mkDefault 10;
      consoleMode = lib.mkDefault "max";
    };
    boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
    boot.tmp = {
      useTmpfs = lib.mkDefault true;
      tmpfsHugeMemoryPages = lib.mkDefault "within_size";
    };
    zramSwap.enable = lib.mkDefault true;

    services.qemuGuest.enable = cfg.virtualization == "qemu";
    virtualisation.vmware.guest.enable = cfg.virtualization == "vmware";

    time.timeZone = lib.mkDefault "Europe/Berlin";
    i18n = {
      defaultLocale = cfg.locale.language;
      extraLocales = [
        "${cfg.locale.language}/UTF-8"
        "${cfg.locale.format}/UTF-8"
      ];
      extraLocaleSettings = {
        LC_MESSAGES = cfg.locale.language;
        LC_ADDRESS = cfg.locale.format;
        LC_IDENTIFICATION = cfg.locale.format;
        LC_MEASUREMENT = cfg.locale.format;
        LC_MONETARY = cfg.locale.format;
        LC_NAME = cfg.locale.format;
        LC_NUMERIC = cfg.locale.format;
        LC_PAPER = cfg.locale.format;
        LC_TELEPHONE = cfg.locale.format;
        LC_TIME = cfg.locale.format;
      };
    };
    console = {
      keyMap = cfg.locale.consoleKeyMap;
      packages = [ pkgs.terminus_font ];
      font = "${pkgs.terminus_font}/share/consolefonts/ter-v24b.psf.gz";
    };

    systemd.enableStrictShellChecks = true;

  };
}
