{ config, lib, ... }:
let
  cfg = config.nstdl.age;
in
{
  options.nstdl.age = {
    ageBin = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The path to the `age` binary.";
    };

    identityPaths = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = "A list of paths to recipient keys to decrypt secrets.";
    };

    secretsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The directory where secrets are decrypted to by default.";
    };

    secretsMountPoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The directory where secret generations are created before being linked.";
    };

    secretsBaseDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        The base directory where secret files are stored.
        If set, the `file` option for each secret defaults to
        `''${secretsBaseDir}/<secret-name>.age`.
      '';
    };

    secrets = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              file = lib.mkOption {
                type = lib.types.path;
                default =
                  if cfg.secretsBaseDir == null then
                    throw "nstdl.age.secrets.\"${name}\".file must be set, or set nstdl.age.secretsBaseDir."
                  else
                    "${cfg.secretsBaseDir}/${name}.age";
                defaultText = lib.literalExpression ''"''${config.nstdl.age.secretsBaseDir}/<secret-name>.age"'';
                description = "Path to the age-encrypted secret file.";
              };

              acl = lib.mkOption {
                type = lib.types.attrsOf (lib.types.listOf lib.types.str);
                default = { };
                description = ''
                  Access Control List for the secret.
                  An attribute set mapping a hostname to a list of local users
                  who should be granted read access.
                '';
              };

              groupName = lib.mkOption {
                type = lib.types.str;
                default = "secret-${lib.replaceStrings [ "." ] [ "-" ] name}";
                description = "Override the auto-generated group name for this secret.";
              };

              path = lib.mkOption {
                type = lib.types.nullOr lib.types.path;
                default = null;
                description = "Absolute path where the decrypted secret file will be created.";
              };

              owner = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "User who should own the decrypted secret file.";
              };

              group = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Group who should own the decrypted secret file.";
              };

              mode = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Permissions of the decrypted secret file.";
              };

              symlink = lib.mkOption {
                type = lib.types.nullOr lib.types.bool;
                default = null;
                description = "Whether to symlink the secret (true, default) or copy it (false).";
              };

              name = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "The name of the decrypted file, if different from the attribute name.";
              };
            };
          }
        )
      );
      default = { };
      description = "Declaratively manage age secrets with host-specific access control lists.";
    };
  };

  config = lib.mkIf (cfg.secrets != { }) {
    # Pass through top-level age settings to the underlying ragenix module.
    age = {
      ageBin = lib.mkIf (cfg.ageBin != null) cfg.ageBin;
      identityPaths = lib.mkIf (cfg.identityPaths != null) cfg.identityPaths;
      secretsDir = lib.mkIf (cfg.secretsDir != null) cfg.secretsDir;
      secretsMountPoint = lib.mkIf (cfg.secretsMountPoint != null) cfg.secretsMountPoint;
    };

    age.secrets = lib.mapAttrs (
      secretName: secretDef:
      let
        membersForThisHostRaw = secretDef.acl."${config.nstdl.hostConfig.identifier}" or null;
        membersForThisHost =
          if membersForThisHostRaw == null then [ ] else lib.filter (m: m != null) membersForThisHostRaw;
        hasAclForThisHost = membersForThisHost != [ ];

        # These are our module's internal options that shouldn't be passed to ragenix.
        internalAttrs = [
          "acl"
          "groupName"
        ];

        # Pass through all other options from the secret definition to ragenix.
        passthroughAttrs = lib.filterAttrs (n: v: v != null) (
          lib.attrsets.removeAttrs secretDef internalAttrs
        );

        # If there is an ACL for this host, set default ownership and permissions.
        aclAttrs = lib.mkIf hasAclForThisHost {
          group = lib.mkDefault secretDef.groupName;
          mode = lib.mkDefault "0440";
        };
      in
      lib.mkMerge [
        passthroughAttrs
        aclAttrs
      ]
    ) cfg.secrets;

    # Define the user groups required by the ACLs.
    users.groups = lib.mkMerge (
      lib.mapAttrsToList (
        secretName: secretDef:
        let
          membersForThisHostRaw = secretDef.acl."${config.nstdl.hostConfig.identifier}" or null;
          membersForThisHost =
            if membersForThisHostRaw == null then [ ] else lib.filter (m: m != null) membersForThisHostRaw;
          hasAclForThisHost = membersForThisHost != [ ];
        in
        # Only create a group if the ACL for this host is defined and has members.
        lib.mkIf hasAclForThisHost {
          "${secretDef.groupName}" = {
            members = membersForThisHost;
          };
        }
      ) cfg.secrets
    );
  };
}
