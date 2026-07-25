{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nstdl.accounts;
  users = cfg.users;
  userNames = lib.attrNames users;
  administrators = lib.attrNames (lib.filterAttrs (_: user: user.administrator) users);
  root = cfg.root;
in
{
  options.nstdl.accounts = {
    role = lib.mkOption {
      type = lib.types.enum [
        "server"
        "workstation"
      ];
      description = "Host role supplied by the nstdl flake adapter.";
    };
    primary = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Desktop account for a workstation.";
    };
    extraSshUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Explicit host-local SSH accounts in addition to managed accounts.";
    };
    root = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Allow SSH-key-only break-glass access to root.";
      };
      sshKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Public SSH keys authorized for root when break-glass access is enabled.";
      };
    };
    users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            sshKeys = lib.mkOption { type = lib.types.listOf lib.types.str; };
            administrator = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
            hashedPasswordFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Password-hash file, normally config.age.secrets.<name>.path.";
            };
          };
        }
      );
      default = { };
      description = "Resolved account definitions supplied by the flake adapter.";
    };
  };

  config = lib.mkIf (users != { } || root.enable || cfg.extraSshUsers != [ ]) {
    assertions = [
      {
        assertion = cfg.role != "workstation" || (cfg.primary != null && users ? ${cfg.primary});
        message = "nstdl workstation accounts require primary to name a managed account.";
      }
      {
        assertion =
          cfg.role != "server" || lib.all (name: users.${name}.hashedPasswordFile != null) administrators;
        message = "nstdl server administrators require hashedPasswordFile for passworded sudo.";
      }
      {
        assertion = !root.enable || root.sshKeys != [ ];
        message = "nstdl root SSH break-glass access requires at least one public SSH key.";
      }
      {
        assertion = root.enable || !lib.elem "root" cfg.extraSshUsers;
        message = "nstdl root SSH access requires accounts.root.enable = true.";
      }
    ];

    users.mutableUsers = false;
    users.users =
      lib.mapAttrs (
        _name: user:
        {
          isNormalUser = true;
          shell = pkgs.zsh;
          openssh.authorizedKeys.keys = user.sshKeys;
        }
        // lib.optionalAttrs (user.hashedPasswordFile != null) {
          inherit (user) hashedPasswordFile;
        }
      ) users
      // lib.optionalAttrs root.enable {
        root.openssh.authorizedKeys.keys = root.sshKeys;
      };

    users.groups.wheel.members = administrators;
    nix.settings.trusted-users = lib.mkAfter administrators;
    services.openssh.settings = {
      AllowUsers = userNames ++ lib.optional root.enable "root" ++ cfg.extraSshUsers;
      PermitRootLogin = lib.mkIf root.enable "prohibit-password";
    };
    security.sudo.enable = lib.mkDefault true;
    security.sudo.extraRules = lib.mkIf (cfg.role == "workstation" && administrators != [ ]) [
      {
        users = administrators;
        commands = [
          {
            command = "ALL";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };
}
