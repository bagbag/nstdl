{ config, lib, ... }:
let
  cfg = config.nstdl.age;

  # Helper to create a valid group name from the secret name
  getGroupName = secretName: "secret-${lib.replaceStrings [ "." ] [ "-" ] secretName}";
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

  config = lib.mkIf (cfg.secrets != { }) {
    age = {
      ageBin = lib.mkIf (cfg.ageBin != null) cfg.ageBin;
      identityPaths = lib.mkIf (cfg.identityPaths != null) cfg.identityPaths;
      secretsDir = lib.mkIf (cfg.secretsDir != null) cfg.secretsDir;
      secretsMountPoint = lib.mkIf (cfg.secretsMountPoint != null) cfg.secretsMountPoint;
    };

    age.secrets = lib.mapAttrs (
      secretName: secretDef:
      let
        membersForThisHost = secretDef.acl."${config.nstdl.hostConfig.identifier}" or null;
        hasAclForThisHost = membersForThisHost != null && membersForThisHost != [ ];
        groupName = secretDef.groupName or (getGroupName secretName);

        internalAttrs = [
          "acl"
          "groupName"
        ];

        # FIX: Filter out attributes that are null before passing them through.
        passthroughAttrs =
          let
            # First, remove the attributes used only by this module.
            userDefinedAttrs = lib.attrsets.removeAttrs secretDef internalAttrs;
          in
          # Then, filter out any remaining attributes whose value is null.
          lib.filterAttrs (name: value: value != null) userDefinedAttrs;

        # These attributes are added/defaulted when an ACL is active for this host.
        aclAttrs = lib.mkIf hasAclForThisHost {
          group = lib.mkDefault groupName;
          mode = lib.mkDefault "0440";
        };
      in
      # Merge the passthrough attributes from the user with our ACL-based defaults.
      lib.mkMerge [
        passthroughAttrs
        aclAttrs
      ]
    ) cfg.secrets;

    # Generate the `users.groups` definitions for secrets that have an ACL
    # active on the current host.
    users.groups = lib.mkMerge (
      lib.mapAttrsToList (
        secretName: secretDef:
        let
          membersForThisHost = secretDef.acl."${config.nstdl.hostConfig.identifier}" or null;
          hasAclForThisHost = membersForThisHost != null && membersForThisHost != [ ];
          groupName = secretDef.groupName or (getGroupName secretName);
        in
        if hasAclForThisHost then
          {
            "${groupName}" = {
              members = membersForThisHost;
            };
          }
        else
          { }
      ) cfg.secrets
    );
  };
}
