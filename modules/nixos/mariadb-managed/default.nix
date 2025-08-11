{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nstdl.mariadbManaged;

  mkUserManagementCommands =
    userName: userCfg:
    let
      userIdentity = "'${userCfg.user}'@'${userCfg.host}'";
      passwordFile = userCfg.passwordFile;

      mkGlobalPrivilegesCommands =
        let
          privs = lib.concatStringsSep ", " userCfg.globalPrivileges;
        in
        lib.strings.optionalString (userCfg.globalPrivileges != [ ]) ''
          echo "Granting global privileges to ${userIdentity}"
          $MYSQL -e "GRANT ${privs} ON *.* TO ${userIdentity};"
        '';

      mkPrivilegesCommands =
        let
          privilegesByObject = lib.groupBy (p: "${p.database}.${p.table}") userCfg.privileges;

          mkGrantForObject =
            objectKey: privsGroup:
            let
              grants = lib.concatStringsSep ", " (lib.concatMap (p: p.grants) privsGroup);
            in
            ''
              echo "Granting privileges on '${objectKey}' to ${userIdentity}"
              $MYSQL -e "GRANT ${grants} ON ${objectKey} TO ${userIdentity};"
            '';
        in
        lib.concatStringsSep "\n" (lib.mapAttrsToList mkGrantForObject privilegesByObject);

    in
    ''
      # --- Managing user: ${userName} (${userIdentity}) ---
      echo "Configuring MariaDB user: ${userIdentity}"

      # Safely read password from file and escape it for SQL.
      # 1. Escape single quotes and backslashes
      password_sql_escaped=$(${pkgs.coreutils}/bin/cat '${passwordFile}' | ${pkgs.gnused}/bin/sed -e "s/'/'''/g" -e 's/\\/\\\\/g')

      # Use printf to construct the SQL and pipe it to the mysql client.
      # This is the most secure way to handle a password with special characters,
      # as it avoids shell re-interpretation of the password string, preventing
      # command injection vulnerabilities.
      ${pkgs.coreutils}/bin/printf '%s' "CREATE OR REPLACE USER ${userIdentity} IDENTIFIED BY '${"$"}{password_sql_escaped}';" | $MYSQL

      # Now, grant the privileges declared in the configuration.
      ${mkGlobalPrivilegesCommands}
      ${mkPrivilegesCommands}
    '';

  enabledUsers = lib.filterAttrs (n: v: v.enable) cfg.users;
in
{
  options.services.nstdl.mariadbManaged = {
    description = "Declaratively manage MariaDB databases, users, and privileges.";

    ensureDatabases = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = lib.literalExpression ''
        [ "my_app_db", "another_db" ]
      '';
      description = "A list of MariaDB databases to create if they do not exist.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              enable = lib.mkEnableOption "declarative MariaDB user";

              user = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "The MariaDB username. Defaults to the attribute set name.";
              };

              host = lib.mkOption {
                type = lib.types.str;
                default = "localhost";
                description = "The host from which the user can connect. Defaults to 'localhost'. Use '%' for any host.";
              };

              passwordFile = lib.mkOption {
                type = lib.types.path;
                description = "Absolute path to a file containing the user's password.";
              };

              globalPrivileges = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                example = [
                  "SUPER"
                  "RELOAD"
                ];
                description = "List of global privileges to grant to the user (e.g. SUPER, RELOAD, PROCESS). These are granted `ON *.*`.";
              };

              privileges = lib.mkOption {
                type = lib.types.listOf (
                  lib.types.submodule {
                    options = {
                      database = lib.mkOption {
                        type = lib.types.str;
                        description = "The name of the database where the grant will occur.";
                      };
                      table = lib.mkOption {
                        type = lib.types.str;
                        default = "*";
                        description = "The table to grant privileges on. Defaults to '*' for all tables in the database.";
                      };
                      grants = lib.mkOption {
                        type = lib.types.listOf lib.types.str;
                        description = "A list of privileges to grant.";
                        example = [
                          "SELECT"
                          "INSERT"
                          "UPDATE"
                        ];
                      };
                    };
                  }
                );
                default = [ ];
                example = lib.literalExpression ''
                  [
                    # Grant SELECT, INSERT, and UPDATE on all tables in my_app_db
                    { database = "my_app_db"; grants = [ "SELECT" "INSERT" "UPDATE" ]; }

                    # Grant ALL PRIVILEGES on a specific table
                    { database = "other_db"; table = "important_table"; grants = [ "ALL PRIVILEGES" ]; }
                  ]
                '';
                description = "A list of database-specific privileges to grant to this user. All privileges for the same database/table are automatically combined into a single GRANT statement.";
              };
            };
          }
        )
      );
      default = { };
      description = "An attribute set of MariaDB users to manage.";
    };
  };

  config = lib.mkIf (cfg.ensureDatabases != [ ] || enabledUsers != { }) {
    assertions = [
      {
        assertion = config.services.mysql.enable;
        message = "services.nstdl.mariadbManaged requires services.mysql.enable to be true.";
      }
    ];

    services.mysql.ensureDatabases = cfg.ensureDatabases;

    systemd.services.mysql.postStart = lib.mkAfter ''
      set -euo pipefail

      echo "--- Running mariadb-managed script ---"
      MYSQL="${pkgs.mariadb}/bin/mysql --user=mysql"

      # Before making changes, ensure the privilege tables are up to date.
      $MYSQL -e "FLUSH PRIVILEGES;"

      ${lib.concatStringsSep "\n" (lib.mapAttrsToList mkUserManagementCommands enabledUsers)}

      echo "Flushing privileges."
      $MYSQL -e "FLUSH PRIVILEGES;"
      echo "--- mariadb-managed script finished successfully ---"
    '';
  };
}
