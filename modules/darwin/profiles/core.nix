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
      description = "Accepted by the shared host schema; Darwin does not set it.";
    };

    user = {
      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Primary user. A profile never creates one by default.";
      };

      authorizedKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "SSH public keys for the primary user.";
      };

    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.user.name != null;
        message = "nstdl Darwin profiles require nstdl.user.name.";
      }
    ];

    nixpkgs.config.allowUnfree = true;
    nix = {
      package = pkgs.lix;
      settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        substituters = [ "https://nix-community.cachix.org" ];
        trusted-public-keys = [
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        ];
      };
      gc = {
        automatic = lib.mkDefault true;
        interval = {
          Hour = lib.mkDefault 8;
          Minute = lib.mkDefault 0;
        };
        options = lib.mkDefault "--delete-older-than 7d";
      };
      optimise = {
        automatic = lib.mkDefault true;
        interval = {
          Hour = lib.mkDefault 8;
          Minute = lib.mkDefault 0;
        };
      };
    };
    networking.hostName = cfg.hostName;
    environment.shells = [ pkgs.nushell ];

    users.users = lib.mkIf (cfg.user.name != null) {
      ${cfg.user.name} = {
        home = "/Users/${cfg.user.name}";
        shell = pkgs.zsh;
        openssh.authorizedKeys.keys = cfg.user.authorizedKeys;
      };
    };

    system.primaryUser = lib.mkIf (cfg.user.name != null) cfg.user.name;
  };
}
