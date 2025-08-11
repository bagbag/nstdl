{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nstdl.interactiveUsers;
  allManagedUsers = lib.attrNames cfg.users;
in
{
  options.nstdl.interactiveUsers = {
    enable = mkEnableOption "nstdl user management module";

    defaultSshKeys = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        A list of public SSH keys that will be added to all managed users,
        including the root user.
      '';
    };

    users = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            isAdmin = mkOption {
              type = types.bool;
              default = false;
              description = ''
                If true, the user will be granted passwordless `sudo` and `doas` access.
              '';
            };

            extraSshKeys = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "A list of extra SSH keys specific to this user.";
            };

            hashedPasswordFile = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = ''
                Path to a file containing the user's hashed password.
                Typically used with a secret management tool like age.
                Example: config.age.secrets."my-user.password-hash".path
              '';
            };
          };
        }
      );
      default = { };
      description = ''
        An attribute set of users to create and manage.
        The key of each attribute is the username.
      '';
      example = literalExpression ''
        {
          alice = {
            isAdmin = true;
            hashedPasswordFile = config.age.secrets."alice.password-hash".path;
            extraSshKeys = [ "ssh-ed25519 AAAA..." ];
          };
          bob = { };
        }
      '';
    };
  };

  config = mkIf cfg.enable {
    users.mutableUsers = mkDefault false;

    users.users =
      {
        root = {
          isNormalUser = false;
          shell = pkgs.zsh;
          openssh.authorizedKeys.keys = cfg.defaultSshKeys;
        };
      }
      // (mapAttrs' (
        username: userOpts:
        nameValuePair username {
          isNormalUser = true;
          shell = pkgs.zsh;
          openssh.authorizedKeys.keys = cfg.defaultSshKeys ++ userOpts.extraSshKeys;
        }
        // optionalAttrs (userOpts.hashedPasswordFile != null) {
          hashedPasswordFile = userOpts.hashedPasswordFile;
        }
      ) cfg.users);

    snowfallorg.users =
      {
        root = {
          home.enable = true;
        };
      }
      // (mapAttrs' (
        username: userOpts:
        nameValuePair username {
          home.enable = true;
        }
        // optionalAttrs userOpts.isAdmin {
          admin = true;
        }
      ) cfg.users);

    nix.settings.trusted-users = [
      "root"
      "@wheel"
    ];

    services.openssh.settings.AllowUsers = [ "root" ] ++ allManagedUsers;
  };
}
