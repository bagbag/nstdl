{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nstdl.postgresql.backup;
  package = config.services.nstdl.postgresql.tool;
  locationType = lib.types.addCheck lib.types.nonEmptyStr (
    path: path != "/" && lib.hasPrefix "/" path
  );
  reconcileUnit = "nstdl-postgresql-reconcile.service";
  hasReconcile = config.systemd.services ? nstdl-postgresql-reconcile;
  restore = pkgs.writeShellScript "nstdl-postgresql-restore" ''
    if [[ "$(id -u)" -ne 0 ]]; then
      echo "nstdl postgresql restore: run it as root (sudo)" >&2
      exit 1
    fi
    NSTDL_PROG="nstdl postgresql" exec ${lib.getExe package} restore ${
      lib.optionalString hasReconcile "--reconcile-unit ${reconcileUnit}"
    } "$@"
  '';
in
{
  imports = [ ../commands.nix ];

  options.services.nstdl.postgresql.backup = {
    enable = lib.mkEnableOption "local backup sets of every PostgreSQL database and the roles";
    exclude = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      default = [ ];
      example = [ "app_staging" ];
      description = "Databases left out of each set, by exact name; a name matching no database logs a warning.";
    };
    location = lib.mkOption {
      type = locationType;
      default = "/var/lib/nstdl-postgresql-backup";
      description = "Directory holding the backup sets; created for the postgres user.";
    };
    calendar = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "daily";
      description = "systemd OnCalendar expression; null runs backups only on demand.";
    };
    keep = {
      daily = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 7;
        description = "Keep the newest set of each of this many most recent days that have one.";
      };
      weekly = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 4;
        description = "Keep the newest set of each of this many most recent ISO weeks that have one.";
      };
      monthly = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 6;
        description = "Keep the newest set of each of this many most recent months that have one.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.postgresql.enable;
        message = "services.nstdl.postgresql.backup requires services.postgresql.enable.";
      }
    ];

    systemd.tmpfiles.settings.nstdl-postgresql-backup.${cfg.location}.d = {
      user = "postgres";
      group = "postgres";
      mode = "0700";
    };

    systemd.services.nstdl-postgresql-backup = {
      description = "nstdl PostgreSQL backup set";
      requires = [ "postgresql-setup.service" ];
      after = [
        "postgresql.service"
        "postgresql-setup.service"
      ];
      # A script, not ExecStart: systemd would expand `%` and `$` in database names.
      script = "exec ${
        lib.escapeShellArgs (
          [
            (lib.getExe package)
            "backup"
            "--location"
            cfg.location
            "--keep-daily"
            (toString cfg.keep.daily)
            "--keep-weekly"
            (toString cfg.keep.weekly)
            "--keep-monthly"
            (toString cfg.keep.monthly)
          ]
          ++ lib.concatMap (name: [
            "--exclude"
            name
          ]) cfg.exclude
        )
      }";
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
        UMask = "0077";
        ReadWritePaths = [ cfg.location ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };

    systemd.timers.nstdl-postgresql-backup = lib.mkIf (cfg.calendar != null) {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.calendar;
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
    };

    nstdl.commands.postgresql.restore = {
      program = restore;
      description = "SET [--yes]  restore the roles and every database of a backup set";
    };
  };
}
