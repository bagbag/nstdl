{ config, lib, ... }:
let
  cfg = config.nstdl.age;
in
{
  options.nstdl.age = {
    # ... options section is unchanged ...
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
                type = lib.types.nullOr lib.types.str;
                default = null;
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

  config = lib.mkIf (cfg.secrets != { }) (
    let
      processedSecrets = lib.mapAttrs (
        secretName: secretDef:
        let
          # Helper to create a valid group name from the secret name
          getGroupName = secretName: "secret-${lib.replaceStrings [ "." ] [ "-" ] secretName}";

          # Look up the members for the current host's identifier from the acl.
          # The `or null` handles cases where the identifier isn't in the acl map.
          membersForThisHostRaw = secretDef.acl."${config.nstdl.hostConfig.identifier}" or null;

          # Filter out any null members from the list, in case the list contains dynamic
          # references that evaluate to null (e.g., a user that doesn't exist on this host).
          membersForThisHost =
            if membersForThisHostRaw == null then null else lib.filter (m: m != null) membersForThisHostRaw;

          # A secret has a relevant ACL for this host if the member list exists and is not empty.
          hasAclForThisHost = membersForThisHost != null && membersForThisHost != [ ];

          # Determine the group name, using the override if it exists, otherwise generating it.
          groupName = secretDef.groupName // (getGroupName secretName);
        in
        {
          # Pass through original definition for reference
          inherit secretDef;
          # Add our processed values
          inherit hasAclForThisHost membersForThisHost groupName;
        }
      ) cfg.secrets;

      # Create a new attrset containing only the secrets that have a non-empty ACL for this host.
      secretsWithAclForThisHost = lib.filterAttrs (
        secretName: processed: processed.hasAclForThisHost
      ) processedSecrets;
    in
    {
      age = {
        ageBin = lib.mkIf (cfg.ageBin != null) cfg.ageBin;
        identityPaths = lib.mkIf (cfg.identityPaths != null) cfg.identityPaths;
        secretsDir = lib.mkIf (cfg.secretsDir != null) cfg.secretsDir;
        secretsMountPoint = lib.mkIf (cfg.secretsMountPoint != null) cfg.secretsMountPoint;
      };

      age.secrets = lib.mapAttrs (
        secretName: processed:
        let
          internalAttrs = [
            "acl"
            "groupName"
          ];

          passthroughAttrs = lib.filterAttrs (n: v: v != null) (
            lib.attrsets.removeAttrs processed.secretDef internalAttrs
          );

          aclAttrs = lib.mkIf processed.hasAclForThisHost {
            group = lib.mkDefault processed.groupName;
            mode = lib.mkDefault "0440";
          };
        in
        lib.mkMerge [
          passthroughAttrs
          aclAttrs
        ]
      ) processedSecrets;

      users.groups = lib.attrsets.mapAttrsToAttrs (
        secretName: processed:
        lib.attrsets.singleton processed.groupName {
          members = processed.membersForThisHost;
        }
      ) secretsWithAclForThisHost;
    }
  );
}
