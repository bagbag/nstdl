{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nstdl.postgresqlBackup;

  postgresqlPackage = config.services.postgresql.package;

  mkBackupService =
    {
      name,
      dumpBinary,
      dumpArgs,
      format,
    }:
    let
      useNativeCompression = (dumpBinary == "pg_dump") && (format == "custom");

      compressionConfig =
        let
          # For custom format, compression is handled by pg_dump, so no suffix is needed
          suffix =
            if format == "custom" then
              ""
            else
              {
                "none" = "";
                "gzip" = ".gz";
                "zstd" = ".zst";
              }
              .${cfg.compression};
        in
        {
          "none" = {
            inherit suffix;
            command = "cat";
          };
          "gzip" = {
            inherit suffix;
            command = "${pkgs.gzip}/bin/gzip -c -${toString cfg.compressionLevel}";
          };
          "zstd" = {
            inherit suffix;
            command = "${pkgs.zstd}/bin/zstd -c -${toString cfg.compressionLevel}";
          };
        }
        .${cfg.compression};

      formatConfig =
        {
          "plain" = {
            extension = "sql";
            extraDumpArgs = if dumpBinary == "pg_dump" && cfg.createDatabaseStatement then [ "-C" ] else [ ];
          };
          "custom" = {
            extension = "dump";
            extraDumpArgs = [ "-Fc" ];
          };
        }
        .${format};

      # Arguments for pg_dump's native compression.
      # For 'none', we must explicitly set level 0, as the default for custom format is gzip.
      nativeCompressionArgs =
        if cfg.compression == "none" then
          [ "--compress=0" ]
        else
          [ "--compress=${cfg.compression}:${toString cfg.compressionLevel}" ];

      finalDumpArgs =
        cfg.commonOptions
        ++ dumpArgs
        ++ formatConfig.extraDumpArgs
        ++ (lib.optionals useNativeCompression nativeCompressionArgs);

      backupCommand =
        if useNativeCompression then
          # For custom format, use native compression and direct output redirection.
          ''
            ${postgresqlPackage}/bin/${dumpBinary} ${lib.escapeShellArgs finalDumpArgs} > "$IN_PROGRESS_FILE"
          ''
        else
          # For pg_dumpall or plain format, pipe the output to an external compressor.
          ''
            ${postgresqlPackage}/bin/${dumpBinary} ${lib.escapeShellArgs finalDumpArgs} \
              | ${compressionConfig.command} > "$IN_PROGRESS_FILE"
          '';

      cleanupScript = pkgs.writeShellScript "postgresql-cleanup-${name}" ''
        set -e
        echo "Cleaning up old backups for '${name}'..."
        find ${lib.escapeShellArg cfg.location} -name "${name}-*" -mtime +${toString cfg.retentionDays} -delete
        echo "Cleanup complete."
      '';
    in
    {
      description = "Backup of ${name} database(s)";

      wantedBy = [ "postgresql-backup.target" ];
      requires = [ "postgresql.service" ];
      after = [ "postgresql.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;

        ReadWritePaths = [ cfg.location ];

        ExecStartPre = pkgs.writeShellScript "postgresql-backup-prepare-${name}" ''
          set -e
          # In case a previous run failed, remove any stale in-progress file.
          rm -f ${lib.escapeShellArg "${cfg.location}/${name}.in-progress.${formatConfig.extension}${compressionConfig.suffix}"}
        '';

        ExecStart = pkgs.writeShellScript "postgresql-backup-run-${name}" ''
          set -eu -o pipefail

          # umask is set to 077 by default with systemd, but we can be explicit.
          umask 0077

          TIMESTAMP=$(date +%Y-%m-%d-%H%M%S)
          FINAL_FILE="${cfg.location}/${name}-$TIMESTAMP.${formatConfig.extension}${compressionConfig.suffix}"
          IN_PROGRESS_FILE="${cfg.location}/${name}.in-progress.${formatConfig.extension}${compressionConfig.suffix}"

          echo "Starting backup of '${name}' to $FINAL_FILE"

          ${backupCommand}

          # Atomically move the completed backup to its final destination.
          mv "$IN_PROGRESS_FILE" "$FINAL_FILE"
          echo "Backup of '${name}' completed successfully."
        '';

        ExecStartPost = lib.optionalString (cfg.retentionDays != null) "-${cleanupScript}";

        # Standard hardening options.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    }
    // lib.optionalAttrs (cfg.onFailure != null) {
      onFailure = cfg.onFailure;
    };

in
{
  options.services.nstdl.postgresqlBackup = {
    enable = lib.mkEnableOption "PostgreSQL scheduled backups";

    user = lib.mkOption {
      type = lib.types.str;
      default = "postgres";
      description = "User to run the backup as. This user must have read access to the database and write access to the backup location.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "postgres";
      description = "Group for the backup user and backup files.";
    };

    location = lib.mkOption {
      default = "/var/backup/postgresql";
      type = lib.types.path;
      description = "Directory where the PostgreSQL database dumps will be placed.";
    };

    calendar = lib.mkOption {
      default = "*-*-* 01:15:00";
      type = with lib.types; either str (listOf str);
      description = "A `systemd.time` calendar expression that specifies when the backups should run.";
      example = "daily";
    };

    randomizedDelaySec = lib.mkOption {
      type = lib.types.str;
      default = "30m";
      description = ''
        Adds a randomized delay to the timer. This is useful to prevent a "thundering herd"
        if many machines are scheduled to back up at the same time. Set to 0 to disable.
        See `RandomizedDelaySec` in `systemd.timer(5)`.
      '';
    };

    backupAll = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.databases == [ ];
        defaultText = lib.literalExpression "`services.nstdl.postgresqlBackup.databases` is empty";
        description = ''
          If true, back up all databases using `pg_dumpall`.
          This is the default behavior if no specific `databases` are listed.
        '';
      };

      globalsOnly = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          When using `pg_dumpall`, only dump global objects (roles and tablespaces),
          not the data. This is useful for creating a separate, small backup of your
          cluster-wide configuration. If this is true, `pg_dumpall` is run with
          the `--globals-only` flag.
        '';
      };

      pgdumpallOptions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          A list of extra command-line options passed only to `pg_dumpall`.
        '';
      };
    };

    databases = lib.mkOption {
      default = [ ];
      type = lib.types.listOf lib.types.str;
      description = ''
        List of specific database names to back up. A separate backup file and
        service will be created for each database using `pg_dump`.
      '';
    };

    format = lib.mkOption {
      type = lib.types.enum [
        "custom"
        "plain"
      ];
      default = "custom";
      description = ''
        The format for `pg_dump`.
        - `custom`: Creates a compressed, custom-format archive (`-Fc`).
          This is the **recommended** format as it is more robust, allows for
          selective restores, and is generally faster. When using this format,
          compression is handled natively by `pg_dump` via the `--compress` flag.
        - `plain`: Creates a plain-text SQL script. Compression is handled by
          piping the output through an external utility (e.g., `gzip`, `zstd`).
        This option is ignored (forced to `plain`) when `backupAll.enable` is true.
      '';
    };

    createDatabaseStatement = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        When using `format = "plain"`, include the `CREATE DATABASE` statement
        in the backup (`-C` flag for `pg_dump`). This is ignored for the `custom`
        format, as `pg_restore` handles database creation.
      '';
    };

    retentionDays = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = 30;
      description = ''
        The number of days to keep backups. Old backups are deleted automatically
        after a successful backup. Set to `null` to disable cleanup.
      '';
      example = 14;
    };

    commonOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "--host=/run/postgresql" ];
      description = ''
        A list of command-line options to pass to both `pg_dump` and `pg_dumpall`.
        The default ensures connection via the standard socket.
      '';
      example = [
        "--host=localhost"
        "--port=5433"
      ];
    };

    compression = lib.mkOption {
      type = lib.types.enum [
        "none"
        "gzip"
        "zstd"
      ];
      default = "zstd";
      description = "The type of compression to use on the database dump.";
    };

    compressionLevel = lib.mkOption {
      type = lib.types.ints.between 1 19;
      default = if cfg.compression == "zstd" then 10 else 6;
      defaultText = lib.literalExpression ''if config.services.nstdl.postgresqlBackup.compression == "zstd" then 10 else 6'';
      description = ''
        The compression level to use.
        `gzip` accepts levels from 1 (fastest) to 9 (best compression).
        `zstd` accepts levels from 1 (fastest) to 19 (best compression).
      '';
    };

    onFailure = lib.mkOption {
      type = with lib.types; nullOr (listOf str);
      default = null;
      description = ''
        A list of systemd units to activate when any backup job fails.
        See `OnFailure=` in `systemd.service(5)`.
      '';
      example = [ "failure-notification.service" ];
    };
  };

  config = lib.mkIf cfg.enable (
    let
      backupJobs =
        let
          allJob = {
            name = if cfg.backupAll.globalsOnly then "all-globals" else "all-databases";
            dumpBinary = "pg_dumpall";
            dumpArgs =
              cfg.backupAll.pgdumpallOptions ++ (lib.optional cfg.backupAll.globalsOnly "--globals-only");
            format = "plain"; # pg_dumpall only supports plain text
          };
          dbJobs = map (dbName: {
            name = dbName;
            dumpBinary = "pg_dump";
            dumpArgs = [ "--dbname=${dbName}" ];
            format = cfg.format;
          }) cfg.databases;
        in
        (lib.optionals cfg.backupAll.enable [ allJob ]) ++ dbJobs;
    in
    {
      assertions = [
        {
          assertion = !(cfg.backupAll.enable && !cfg.backupAll.globalsOnly && cfg.databases != [ ]);
          message = "`services.nstdl.postgresqlBackup.backupAll.enable` (for a full data dump) and `services.nstdl.postgresqlBackup.databases` are mutually exclusive. Use one or the other, or set `backupAll.globalsOnly = true;` to backup globals alongside specific databases.";
        }
        {
          assertion = cfg.backupAll.enable || cfg.databases != [ ];
          message = "PostgreSQL backup is enabled, but no databases are configured. Set `services.nstdl.postgresqlBackup.backupAll.enable = true;` or specify a list in `services.nstdl.postgresqlBackup.databases`.";
        }
        {
          assertion = !(cfg.backupAll.enable && cfg.format == "custom");
          message = "`backupAll` (using pg_dumpall) only supports plain-text format. This module forces `format` to `plain` automatically, but your configuration explicitly sets it to `custom`. Please remove the explicit `format = \"custom\"` when `backupAll.enable` is true.";
        }
        {
          assertion =
            (cfg.compression == "gzip" && cfg.compressionLevel >= 1 && cfg.compressionLevel <= 9)
            || (cfg.compression == "zstd" && cfg.compressionLevel >= 1 && cfg.compressionLevel <= 19)
            || (cfg.compression == "none");
          message = "Invalid `compressionLevel` for selected `compression` method. gzip requires 1-9, zstd requires 1-19.";
        }
      ];

      systemd.tmpfiles.rules = [
        "d ${cfg.location} 0700 ${cfg.user} ${cfg.group} - -"
      ];

      systemd.targets."postgresql-backup" = {
        description = "PostgreSQL Backup Target";

        unitConfig = {
          StopWhenUnneeded = true;
        };
      };

      systemd.timers."postgresql-backup" = {
        description = "Timer for PostgreSQL Backups";
        timerConfig = {
          OnCalendar = cfg.calendar;
          RandomizedDelaySec = cfg.randomizedDelaySec;
          Persistent = true;
          Unit = "postgresql-backup.target";
        };
        wantedBy = [ "timers.target" ];
      };

      systemd.services = lib.listToAttrs (
        map (job: lib.nameValuePair "postgresql-backup-${job.name}" (mkBackupService job)) backupJobs
      );
    }
  );
}
