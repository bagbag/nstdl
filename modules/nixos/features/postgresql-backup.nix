{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nstdl.postgresql.backup;
  enabledJobs = lib.filterAttrs (_: job: job.enable) cfg.jobs;
  runtimeDirectoryType = lib.types.addCheck lib.types.nonEmptyStr (
    path: path != "/" && lib.hasPrefix "/" path
  );
  jobNameType = lib.types.addCheck lib.types.str (
    name: builtins.match "^[A-Za-z0-9_]+$" name != null
  );
  databaseNameType = lib.types.addCheck lib.types.nonEmptyStr (
    name: builtins.match "^[A-Za-z_][A-Za-z0-9_$]*$" name != null
  );
  compressionSuffix =
    compression:
    {
      none = "";
      gzip = ".gz";
      zstd = ".zst";
    }
    .${compression};
  compressionLevel =
    job:
    if job.compressionLevel != null then
      job.compressionLevel
    else if job.compression == "gzip" then
      6
    else
      10;
  dumpFormat = job: if job.kind == "database" then job.format else "plain";
  extension =
    job: if dumpFormat job == "custom" then ".dump" else ".sql${compressionSuffix job.compression}";
  dumpCommand =
    job:
    let
      pgDumpArgs = [
        "--dbname=${job.database}"
      ]
      ++ lib.optional (job.format == "custom") "--format=custom"
      ++ lib.optional (job.format == "plain" && job.createDatabaseStatement) "--create";
      customCompression = [
        (
          if job.compression == "none" then
            "--compress=0"
          else
            "--compress=${job.compression}:${toString (compressionLevel job)}"
        )
      ];
      compressionCommand =
        {
          none = "${pkgs.coreutils}/bin/cat";
          gzip = "${pkgs.gzip}/bin/gzip -c -${toString (compressionLevel job)}";
          zstd = "${pkgs.zstd}/bin/zstd -c -${toString (compressionLevel job)}";
        }
        .${job.compression};
    in
    if job.kind == "database" && job.format == "custom" then
      "${config.services.postgresql.package}/bin/pg_dump ${
        lib.escapeShellArgs (pgDumpArgs ++ customCompression)
      } > \"$inProgress\""
    else
      let
        command =
          if job.kind == "database" then
            "${config.services.postgresql.package}/bin/pg_dump ${lib.escapeShellArgs pgDumpArgs}"
          else if job.kind == "globals" then
            "${config.services.postgresql.package}/bin/pg_dumpall --globals-only"
          else
            "${config.services.postgresql.package}/bin/pg_dumpall";
      in
      "${command} | ${compressionCommand} > \"$inProgress\"";
in
{
  options.services.nstdl.postgresql.backup = {
    enable = lib.mkEnableOption "local PostgreSQL dump backups";
    location = lib.mkOption {
      type = runtimeDirectoryType;
      default = "/var/lib/nstdl-postgresql-backup";
      description = "Dedicated absolute runtime directory for completed dump files.";
    };
    defaults = {
      user = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "postgres";
        description = "System user that runs backup jobs.";
      };
      group = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "postgres";
        description = "System group that owns backup files.";
      };
      calendar = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "daily";
        description = "Timer schedule for jobs unless overridden; null makes a job manual-only.";
      };
      persistent = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run a missed scheduled job after boot.";
      };
      randomizedDelaySec = lib.mkOption {
        type = lib.types.str;
        default = "30m";
        description = "Timer random delay for jobs unless overridden.";
      };
      retentionDays = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = 30;
        description = "Completed dump retention for jobs unless overridden; null disables cleanup.";
      };
      compression = lib.mkOption {
        type = lib.types.enum [
          "none"
          "gzip"
          "zstd"
        ];
        default = "zstd";
        description = "Compression for jobs unless overridden.";
      };
    };
    jobs = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
              };
              name = lib.mkOption {
                type = jobNameType;
                default = name;
                readOnly = true;
                description = "Filename-safe job name derived from the attribute name.";
              };
              kind = lib.mkOption {
                type = lib.types.enum [
                  "database"
                  "cluster"
                  "globals"
                ];
                default = "database";
                description = "Dump one database, the complete cluster, or only global roles and tablespaces.";
              };
              database = lib.mkOption {
                type = lib.types.nullOr databaseNameType;
                default = if name == "" then null else name;
                description = "Unquoted PostgreSQL database identifier for a database job; defaults to the job name.";
              };
              format = lib.mkOption {
                type = lib.types.enum [
                  "custom"
                  "plain"
                ];
                default = "custom";
                description = "pg_dump output format. Cluster and globals jobs always use plain SQL.";
              };
              createDatabaseStatement = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Include CREATE DATABASE in a plain database dump; ignored for custom, cluster, and globals jobs.";
              };
              compression = lib.mkOption {
                type = lib.types.enum [
                  "none"
                  "gzip"
                  "zstd"
                ];
                default = cfg.defaults.compression;
                description = "Dump compression.";
              };
              compressionLevel = lib.mkOption {
                type = lib.types.nullOr (lib.types.ints.between 1 19);
                default = null;
                description = "Compression level; null selects gzip level 6 or zstd level 10.";
              };
              retentionDays = lib.mkOption {
                type = lib.types.nullOr lib.types.ints.positive;
                default = cfg.defaults.retentionDays;
                description = "Days to retain this job's completed dumps; null disables cleanup.";
              };
              calendar = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = cfg.defaults.calendar;
                description = "systemd OnCalendar expression, or null for manual-only.";
              };
              persistent = lib.mkOption {
                type = lib.types.bool;
                default = cfg.defaults.persistent;
                description = "Run a missed timer after boot.";
              };
              randomizedDelaySec = lib.mkOption {
                type = lib.types.str;
                default = cfg.defaults.randomizedDelaySec;
                description = "systemd timer random delay.";
              };
            };
          }
        )
      );
      default = { };
      description = "Explicit PostgreSQL dump jobs.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = lib.flatten (
      lib.mapAttrsToList (name: job: [
        {
          assertion = config.services.postgresql.enable;
          message = "services.nstdl.postgresql.backup requires services.postgresql.enable.";
        }
        {
          assertion = job.kind != "database" || job.database != null;
          message = "postgresql backup job '${name}' must set database when kind is database.";
        }
        {
          assertion = job.kind == "database" || job.format == "plain";
          message = "postgresql backup job '${name}' uses pg_dumpall and therefore requires format = plain.";
        }
        {
          assertion = job.compression != "gzip" || job.compressionLevel == null || job.compressionLevel <= 9;
          message = "postgresql backup job '${name}' gzip compressionLevel must be between 1 and 9.";
        }
      ]) enabledJobs
    );

    systemd.targets.nstdl-postgresql-backup = {
      description = "nstdl PostgreSQL backup jobs";
      wants = lib.mapAttrsToList (name: _: "nstdl-postgresql-backup-${name}.service") enabledJobs;
    };
    systemd.services = lib.mapAttrs' (
      name: job:
      lib.nameValuePair "nstdl-postgresql-backup-${name}" {
        description = "nstdl PostgreSQL backup '${name}'";
        requires = [ "postgresql-setup.service" ];
        after = [
          "postgresql.service"
          "postgresql-setup.service"
        ];
        script = ''
          set -euo pipefail
          umask 0077
          timestamp="$(${pkgs.coreutils}/bin/date +%Y-%m-%d-%H%M%S-%N)"
          completed="${cfg.location}/${job.name}-$timestamp${extension job}"
          inProgress="${cfg.location}/.${job.name}.in-progress${extension job}"
          ${pkgs.coreutils}/bin/rm -f "$inProgress"
          ${dumpCommand job}
          ${pkgs.coreutils}/bin/mv --no-clobber "$inProgress" "$completed"
          test ! -e "$inProgress"
          ${lib.optionalString (job.retentionDays != null) ''
            ${pkgs.findutils}/bin/find ${lib.escapeShellArg cfg.location} -maxdepth 1 -type f -name ${lib.escapeShellArg "${job.name}-*${extension job}"} -mtime +${toString job.retentionDays} -delete
          ''}
        '';
        serviceConfig = {
          Type = "oneshot";
          User = cfg.defaults.user;
          Group = cfg.defaults.group;
          StateDirectory = "nstdl-postgresql-backup";
          StateDirectoryMode = "0700";
          ReadWritePaths = [ cfg.location ];
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
        };
      }
    ) enabledJobs;
    systemd.timers = lib.mapAttrs' (
      name: job:
      lib.nameValuePair "nstdl-postgresql-backup-${name}" {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = job.calendar;
          Persistent = job.persistent;
          RandomizedDelaySec = job.randomizedDelaySec;
        };
      }
    ) (lib.filterAttrs (_: job: job.calendar != null) enabledJobs);
  };
}
