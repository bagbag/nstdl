{ config, lib, ... }:
let
  cfg = config.nstdl.age;

  # Helper to create a valid group name from the secret name
  getGroupName = secretName: "secret-${lib.replaceStrings [ "." ] [ "-" ] secretName}";
in
{
  options = {
    nstdl.age.secretsBaseDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        The base directory where secret files are stored.
        If set, the `file` option for each secret defaults to
        `''${secretsBaseDir}/<secret-name>.age`.
      '';
    };

    nstdl.age.secrets = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            # Free-form attributes allow passing any standard `age.secrets.<name>` option
            freeformType = with lib.types; attrsOf anything;

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
            };
          }
        )
      );
      default = { };
      description = "Declaratively manage age secrets with host-specific access control lists.";
    };
  };

  config = lib.mkIf (cfg.secrets != { }) (
    lib.mkMerge (
      lib.mapAttrsToList (
        secretName: secretDef:
        let
          membersForThisHost = secretDef.acl."${config.nstdl.hostConfig.identifier}" or null;
          hasAclForThisHost = membersForThisHost != null && membersForThisHost != [ ];
          groupName = secretDef.groupName or (getGroupName secretName);
        in
        lib.mkMerge [
          # 1. Base secret definition (passing through all standard age.secrets options)
          {
            age.secrets."${secretName}" = lib.attrsets.removeAttrs secretDef [
              "acl"
              "groupName"
            ];
          }

          # 2. Group and permission definition for hosts with an ACL
          (lib.mkIf hasAclForThisHost {
            users.groups."${groupName}".members = membersForThisHost;

            age.secrets."${secretName}" = {
              group = lib.mkDefault groupName;
              mode = lib.mkDefault "0440";
            };
          })
        ]
      ) cfg.secrets
    )
  );
}
