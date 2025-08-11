{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nstdl.postgresqlManaged;

  # --- Helpers to generate SQL/Shell commands ---

  # Generates a shell command to create/update a user.
  mkUserCommand =
    userName: userCfg:
    let
      attributesStr = lib.concatStringsSep " " userCfg.attributes;
      passwordFile = userCfg.passwordFile;
    in
    ''
      echo "Configuring PostgreSQL role: ${userCfg.user}"
      # IMPROVEMENT: Use simple $PSQL without -tA, as no output is expected.
      $PSQL <<'SQL'
        DO $$
        DECLARE password TEXT;
        BEGIN
          password := trim(pg_read_file('${passwordFile}'));

          IF EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${userCfg.user}') THEN
            EXECUTE format('ALTER ROLE %I WITH ${attributesStr} LOGIN PASSWORD %L', '${userCfg.user}', password);
          ELSE
            EXECUTE format('CREATE ROLE %I WITH ${attributesStr} LOGIN PASSWORD %L', '${userCfg.user}', password);
          END IF;
        END $$;
      SQL
    '';

  # Generates a command to set a database owner.
  mkOwnerCommand = dbName: dbCfg: ''
    echo "Setting owner of database '${dbName}' to '${dbCfg.owner}'"
    $PSQL <<'SQL'
      DO $$
      BEGIN
        EXECUTE format('ALTER DATABASE %I OWNER TO %I', '${dbName}', '${dbCfg.owner}');
      END $$;
    SQL
  '';

  # Generates all privilege-granting commands for a single user.
  mkPrivilegesCommands =
    userName: userCfg:
    let
      mkGrant = priv: ''
        echo "Granting privileges on ${priv.on} in '${priv.database}' to '${userCfg.user}'"
        $PSQL -d "${priv.database}" <<'SQL'
          DO $$
          BEGIN
            EXECUTE format('GRANT ${priv.grant} ON ${priv.on} TO %I', '${userCfg.user}');
          END $$;
        SQL
      '';
    in
    lib.concatStringsSep "\n" (map mkGrant userCfg.privileges);

  # These values are calculated once and used in the config block.
  enabledUsers = lib.filterAttrs (n: v: v.enable) cfg.users;
  databasesToOwn = lib.filterAttrs (n: v: v.owner != null) cfg.databases;
  databasesToCreate = lib.mapAttrsToList (n: _: n) (
    lib.filterAttrs (n: v: v.ensureExists) cfg.databases
  );
in
{
  options.services.nstdl.postgresqlManaged = {
    description = "Declaratively manage PostgreSQL databases, users, and privileges.";

    databases = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            ensureExists = lib.mkEnableOption "whether this database should be created if it doesn't exist.";
            owner = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "The role that will own this database. This role must be managed in `services.nstdl.postgresqlManaged.users` or exist by other means.";
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        {
          my_app_db = {
            ensureExists = true;
            owner = "my_app_user";
          };
        }
      '';
      description = "An attribute set of PostgreSQL databases to manage.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              enable = lib.mkEnableOption "declarative PostgreSQL user";
              user = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "The PostgreSQL username (role name). Defaults to the attribute set name.";
              };
              passwordFile = lib.mkOption {
                type = lib.types.path;
                description = "Absolute path to a file containing the user's password. The contents will be read on the target machine when the service starts.";
              };
              attributes = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                example = [
                  "SUPERUSER"
                  "CREATEDB"
                ];
                description = "List of role attributes, e.g. SUPERUSER, CREATEDB, NOREPLICATION.";
              };
              privileges = lib.mkOption {
                type = lib.types.listOf (
                  lib.types.submodule {
                    options = {
                      database = lib.mkOption {
                        type = lib.types.str;
                        description = "The name of the database where the grant will occur.";
                      };
                      grant = lib.mkOption {
                        type = lib.types.str;
                        default = "ALL PRIVILEGES";
                        description = ''
                          The privileges to grant (e.g., `'ALL PRIVILEGES'`, `'CONNECT, SELECT'`).

                          **Warning**: This string is used directly in the `GRANT` statement. It is not sanitized.
                        '';
                      };
                      on = lib.mkOption {
                        type = lib.types.str;
                        description = ''
                          The object to grant privileges on (e.g., `'DATABASE "my_db"'`, `'SCHEMA "public"'`, `'ALL TABLES IN SCHEMA "public"'`).

                          **Warning**: This string is used directly in the `ON` clause of the `GRANT` statement. Ensure any identifiers within it are correctly quoted. It is not sanitized.
                        '';
                      };
                    };
                  }
                );
                default = [ ];
                example = lib.literalExpression ''
                  [
                    # Grant connect on the database itself
                    { database = "my_app_db"; on = "DATABASE \"my_app_db\""; grant = "CONNECT"; }
                    # Grant usage on a schema
                    { database = "my_app_db"; on = "SCHEMA \"public\""; grant = "USAGE"; }
                    # Grant select/insert/update on all tables in a schema
                    { database = "my_app_db"; on = "ALL TABLES IN SCHEMA \"public\""; grant = "SELECT, INSERT, UPDATE, DELETE"; }
                  ]
                '';
                description = "A list of database privileges to grant to this user.";
              };
            };
          }
        )
      );
      default = { };
      description = "An attribute set of PostgreSQL users to manage.";
    };
  };

  config = lib.mkIf (cfg.databases != { } || cfg.users != { }) {
    # 1. Ensure databases exist using the standard NixOS option.
    services.postgresql.ensureDatabases = databasesToCreate;

    # 2. Use a dedicated script for all other management tasks.
    systemd.services.postgresql.postStart = lib.mkAfter ''
      # This script runs as the 'postgres' user after the main service starts.
      echo "--- Running postgresql-managed script ---"

      PSQL="${pkgs.postgresql}/bin/psql -v ON_ERROR_STOP=1 --quiet"

      # Create/Update Users
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList mkUserCommand enabledUsers)}

      # Change database owners
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList mkOwnerCommand databasesToOwn)}

      # Grant privileges
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList mkPrivilegesCommands enabledUsers)}

      echo "--- postgresql-managed script finished successfully ---"
    '';
  };
}
