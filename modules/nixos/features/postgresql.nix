{ config, lib, ... }:
let
  cfg = config.services.nstdl.postgresql;

  managedRoles = lib.filterAttrs (_name: role: role.enable) cfg.roles;
  managedDatabases = lib.filterAttrs (_name: database: database.enable) cfg.databases;
  passwordRoles = lib.filterAttrs (_name: role: role.passwordFile != null) managedRoles;
  membershipRoles = lib.filterAttrs (_name: role: role.memberOf != [ ]) managedRoles;
  identifierType = lib.types.addCheck lib.types.nonEmptyStr (
    name: builtins.match "^[A-Za-z_][A-Za-z0-9_$]*$" name != null
  );
  runtimePathType = lib.types.addCheck lib.types.nonEmptyStr (
    path: lib.hasPrefix "/" path && !builtins.hasContext path
  );
in
{
  imports = [ ./postgresql-backup.nix ];

  options.services.nstdl.postgresql = {
    enable = lib.mkEnableOption "nstdl PostgreSQL role and database management";

    roles = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              enable = lib.mkEnableOption "PostgreSQL role '${name}'";
              login = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Allow this role to authenticate.";
              };
              passwordFile = lib.mkOption {
                type = lib.types.nullOr runtimePathType;
                default = null;
                description = "Runtime path to this role's password; loaded as a systemd credential and never copied into the Nix store.";
              };
              createdb = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Allow this role to create databases.";
              };
              createrole = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Allow this role to create and alter other roles.";
              };
              replication = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Allow this role to initiate replication.";
              };
              inheritRole = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Allow this role to inherit privileges from memberships.";
              };
              connectionLimit = lib.mkOption {
                type = lib.types.nullOr lib.types.int;
                default = null;
                description = "Optional maximum number of concurrent role connections.";
              };
              memberOf = lib.mkOption {
                type = lib.types.listOf identifierType;
                default = [ ];
                description = "Roles granted to this role.";
              };
            };
          }
        )
      );
      default = { };
      description = "PostgreSQL roles managed declaratively by nstdl.";
    };
    databases = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Create and manage this database.";
            };
            owner = lib.mkOption {
              type = lib.types.nullOr identifierType;
              default = null;
              description = "PostgreSQL role that owns this database.";
            };
            extensions = lib.mkOption {
              type = lib.types.listOf identifierType;
              default = [ ];
              description = "Extensions created in this database when their PostgreSQL packages are available.";
            };
          };
        }
      );
      default = { };
      description = "PostgreSQL databases managed declaratively by nstdl.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (name: builtins.match "^[A-Za-z_][A-Za-z0-9_$]*$" name != null) (
          lib.attrNames managedRoles
        );
        message = "nstdl PostgreSQL role names must be unquoted PostgreSQL identifiers.";
      }
      {
        assertion = lib.all (name: builtins.match "^[A-Za-z_][A-Za-z0-9_$]*$" name != null) (
          lib.attrNames managedDatabases
        );
        message = "nstdl PostgreSQL database names must be unquoted PostgreSQL identifiers.";
      }
    ];
    services.postgresql = {
      enable = true;
      ensureDatabases = lib.attrNames managedDatabases;
      ensureUsers = lib.mapAttrsToList (name: role: {
        inherit name;
        ensureClauses = {
          login = role.login;
          "inherit" = role.inheritRole;
          inherit (role) createdb createrole replication;
        }
        // lib.optionalAttrs (role.connectionLimit != null) {
          connection_limit = role.connectionLimit;
        };
      }) managedRoles;
    };

    systemd.services.nstdl-postgresql-reconcile =
      lib.mkIf (managedDatabases != { } || passwordRoles != { } || membershipRoles != { })
        {
          description = "nstdl PostgreSQL ownership and password reconciliation";
          requires = [ "postgresql-setup.service" ];
          after = [
            "postgresql.service"
            "postgresql-setup.service"
          ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            User = "postgres";
          }
          // lib.optionalAttrs (passwordRoles != { }) {
            LoadCredential = lib.mapAttrsToList (
              name: role: "postgresql-role-${name}:${toString role.passwordFile}"
            ) passwordRoles;
          };
          script = lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              name: database:
              lib.optionalString (database.owner != null) ''
                ${config.services.postgresql.package}/bin/psql --set=ON_ERROR_STOP=1 --command ${lib.escapeShellArg "ALTER DATABASE \"${name}\" OWNER TO \"${database.owner}\";"}
              ''
            ) managedDatabases
            ++ lib.concatMap (
              name:
              map (role: ''
                ${config.services.postgresql.package}/bin/psql --set=ON_ERROR_STOP=1 --command ${lib.escapeShellArg "GRANT \"${role}\" TO \"${name}\";"}
              '') membershipRoles.${name}.memberOf
            ) (lib.attrNames membershipRoles)
            ++ lib.concatMap (
              name:
              map (extension: ''
                ${config.services.postgresql.package}/bin/psql --set=ON_ERROR_STOP=1 --dbname ${lib.escapeShellArg name} --command ${lib.escapeShellArg "CREATE EXTENSION IF NOT EXISTS \"${extension}\";"}
              '') managedDatabases.${name}.extensions
            ) (lib.attrNames managedDatabases)
            ++ lib.mapAttrsToList (name: _: ''
              ${config.services.postgresql.package}/bin/psql --set=ON_ERROR_STOP=1 --command "DO \$\$ DECLARE secret text := trim(pg_read_file('$CREDENTIALS_DIRECTORY/postgresql-role-${name}')); BEGIN EXECUTE format('ALTER ROLE %I PASSWORD %L', '${name}', secret); END \$\$;"
            '') passwordRoles
          );
        };
  };
}
