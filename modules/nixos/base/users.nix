{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nstdl.interactiveUsers;
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
                This option is ignored for the root user.
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

            homeStateVersion = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                The state version for this user's Home Manager profile. If set,
                Home Manager will be enabled for this user.
              '';
              example = "25.11";
            };
          };
        }
      );
      default = { };
      description = ''
        An attribute set of users to create and manage.
      '';
      example = literalExpression ''
        {
          root = {
            homeStateVersion = "25.11";
            extraSshKeys = [ "ssh-ed25519 AAAA... root@workstation" ];
          };
          alice = {
            isAdmin = true;
            homeStateVersion = "25.11";
            hashedPasswordFile = config.age.secrets."alice.password-hash".path;
            extraSshKeys = [ "ssh-ed25519 AAAA..." ];
          };
          bob = { }; # bob will not have a Home Manager profile
        }
      '';
    };
  };

  config = mkIf cfg.enable {
    users.mutableUsers = mkDefault false;

    users.users = mapAttrs' (
      username: userOpts:
      let
        isRoot = username == "root";
      in
      nameValuePair username (
        {
          isNormalUser = !isRoot;
          shell = pkgs.zsh;
          openssh.authorizedKeys.keys = cfg.defaultSshKeys ++ (userOpts.extraSshKeys or [ ]);
        }
        // optionalAttrs (userOpts.hashedPasswordFile != null) {
          hashedPasswordFile = userOpts.hashedPasswordFile;
        }
      )
    ) cfg.users;

    snowfallorg.users = mapAttrs' (
      username: userOpts:
      nameValuePair username (
        (optionalAttrs (userOpts.homeStateVersion != null) {
          home.enable = true;
        })
        // (optionalAttrs (username != "root" && (userOpts.isAdmin or false)) {
          admin = true;
        })
      )
    ) cfg.users;

    # Automatically create Home Manager profiles for users where it's enabled.
    home-manager.users =
      let
        usersWithHm = filterAttrs (_: user: user.homeStateVersion != null) cfg.users;
      in
      mapAttrs (_: user: {
        home.stateVersion = user.homeStateVersion;
        imports = [
          ../../home-manager/common.nix
        ];
      }) usersWithHm;

    nix.settings.trusted-users = [
      "root"
      "@wheel"
    ];

    services.openssh.settings.AllowUsers = lib.attrNames cfg.users;
  };
}
