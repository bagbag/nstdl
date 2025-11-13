{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nstdl.proxmox-backup;
  globalConfig = config;

  mkPasswordFile =
    name: text:
    pkgs.writeTextFile {
      inherit name text;
      permissions = "0400";
    };

  # Helper to create environment variables for a password/secret
  mkPasswordEnv =
    {
      name,
      password,
      passwordFile,
      passwordCommand,
      prefix,
    }:
    if password != null then
      { "${prefix}_PASSWORD_FILE" = mkPasswordFile name password; }
    else if passwordFile != null then
      { "${prefix}_PASSWORD_FILE" = passwordFile; }
    else if passwordCommand != null then
      { "${prefix}_PASSWORD_CMD" = passwordCommand; }
    else
      { };

  mkSystemdJob =
    type: name: jobCfg:
    let
      # Build proxmox-backup-client command and arguments in Nix for safety
      backupArgs = [
        "backup"
      ]
      ++ jobCfg.paths
      ++ (lib.optionals (jobCfg.namespace != null) [
        "--ns"
        jobCfg.namespace
      ])
      ++ (lib.optionals (jobCfg.backupType != null) [
        "--backup-type"
        jobCfg.backupType
      ])
      ++ (lib.optionals (jobCfg.backupId != null) [
        "--backup-id"
        jobCfg.backupId
      ])
      ++ (lib.optionals (jobCfg.encryptionKey.keyFile != null) [
        "--keyfile"
        jobCfg.encryptionKey.keyFile
      ])
      ++ (lib.optionals (jobCfg.changeDetectionMode != null) [
        "--change-detection-mode"
        jobCfg.changeDetectionMode
      ])
      ++ (lib.concatMap (p: [
        "--exclude"
        p
      ]) jobCfg.exclude)
      ++ jobCfg.extraBackupArgs;

      pruneArgs = [
        "prune"
        jobCfg.prune.group
      ]
      ++ (lib.mapAttrsToList (n: v: "--keep-${n}=${toString v}") jobCfg.prune.keep)
      ++ jobCfg.prune.extraArgs;

      gcArgs = [ "garbage-collect" ] ++ jobCfg.extraGcArgs;

      backupCommand = "${cfg.package}/bin/proxmox-backup-client ${lib.escapeShellArgs backupArgs}";
      pruneCommand = "${cfg.package}/bin/proxmox-backup-client ${lib.escapeShellArgs pruneArgs}";
      gcCommand = "${cfg.package}/bin/proxmox-backup-client ${lib.escapeShellArgs gcArgs}";

      backupScript = pkgs.writeShellScript "${name}-backup-script" ''
        set -euo pipefail

        # The postHook should run even if the backup fails
        on_exit() {
          exitStatus=$?
          ${jobCfg.postHook}
          exit $exitStatus
        }
        trap on_exit EXIT

        # Run pre-backup hook
        ${jobCfg.preHook}

        echo "Starting Proxmox Backup Client job '${name}'..."
        ${backupCommand}

        # Run prune if enabled
        ${lib.optionalString jobCfg.prune.enable ''
          echo "Pruning backup group '${jobCfg.prune.group}'..."
          ${pruneCommand}
        ''}

        echo "Proxmox Backup Client job '${name}' finished successfully."
      '';

      gcScript = pkgs.writeShellScript "${name}-gc-script" ''
        set -euo pipefail

        on_exit() {
          exitStatus=$?
          ${jobCfg.postHook}
          exit $exitStatus
        }
        trap on_exit EXIT

        ${jobCfg.preHook}

        echo "Starting Proxmox Backup garbage collection job '${name}'..."
        ${gcCommand}
        echo "Proxmox Backup garbage collection job '${name}' finished successfully."
      '';

      baseReadOnlyPaths =
        jobCfg.readOnlyPaths
        ++ (lib.filter (p: p != null) [
          jobCfg.passwordFile
        ]);

      jobSpecifics =
        if type == "backup" then
          let
            sourcePaths = map (p: lib.elemAt (lib.splitString ":" p) 1) jobCfg.paths;
            backupSecretFiles = lib.filter (p: p != null) [
              jobCfg.encryptionKey.keyFile
              jobCfg.encryptionKey.passwordFile
            ];
          in
          {
            description = "Proxmox Backup Client job '${name}'";
            script = backupScript;
            environment = (
              mkPasswordEnv {
                name = "${name}-pbs-encryption-password";
                prefix = "PBS_ENCRYPTION";
                password = jobCfg.encryptionKey.password;
                passwordFile = jobCfg.encryptionKey.passwordFile;
                passwordCommand = jobCfg.encryptionKey.passwordCommand;
              }
            );
            readOnlyPaths = baseReadOnlyPaths ++ sourcePaths ++ backupSecretFiles;
          }
        # type == "gc"
        else
          {
            description = "Proxmox Backup Client garbage collection job '${name}'";
            script = gcScript;
            environment = { };
            readOnlyPaths = baseReadOnlyPaths;
          };
    in
    {
      service = {
        inherit (jobSpecifics) description;
        path = [ cfg.package ];
        script =
          "exec "
          + lib.optionalString jobCfg.inhibitsSleep ''
            ${pkgs.systemd}/bin/systemd-inhibit \
              --who="proxmox-backup" \
              --what="sleep" \
              --why="Scheduled ${type} job ${name}" \
          ''
          + jobSpecifics.script;

        environment = lib.attrsets.mergeAttrsList [
          {
            PBS_REPOSITORY = jobCfg.repository;
          }
          (mkPasswordEnv {
            name = "${name}-pbs-password";
            prefix = "PBS";
            inherit (jobCfg) password passwordFile passwordCommand;
          })
          (lib.optionalAttrs (jobCfg.proxy != null) {
            ALL_PROXY = jobCfg.proxy;
          })
          (lib.optionalAttrs (jobCfg.fingerprint != null) {
            PBS_FINGERPRINT = jobCfg.fingerprint;
          })
          jobSpecifics.environment
        ];

        serviceConfig = {
          Type = "oneshot";
          User = jobCfg.user;
          Group = jobCfg.group;
          # Hardening
          CPUSchedulingPolicy = "idle";
          IOSchedulingClass = "idle";
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          NoNewPrivileges = true;
          CapabilityBoundingSet = "CAP_DAC_OVERRIDE"; # Drop all capabilities except DAC override
          ReadOnlyPaths = jobSpecifics.readOnlyPaths;
        };
      };

      timer = {
        description = "Timer for Proxmox Backup Client ${type} job '${name}'";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = jobCfg.calendar;
          Persistent = jobCfg.persistentTimer;
        };
      };
    };

  # Common options for any job that needs to connect to the repository
  commonJobOptions =
    { name, ... }:
    {
      options = {
        enable = lib.mkEnableOption "this Proxmox Backup Client job" // {
          default = true;
        };

        readOnlyPaths = lib.mkOption {
          type = with lib.types; listOf path;
          default = [ ];
          description = ''
            A list of additional paths that the job needs to be able to read.
            This is necessary because of the systemd hardening options like
            `ProtectSystem` and `ProtectHome`. Source paths for backup jobs and
            paths to password or key files are automatically included.
          '';
        };

        repository = lib.mkOption {
          type = lib.types.str;
          default = cfg.defaults.repository;
          description = ''
            The Proxmox Backup Server repository to connect to.
            Format: `[[username@]server[:port]:]datastore`
          '';
          example = "backup-user@pbs@proxmox.example.com:my-datastore";
        };

        password = lib.mkOption {
          type = with lib.types; nullOr str;
          default = cfg.defaults.password;
          description = ''
            The password or API token secret for the repository.
            This is insecure as it will be stored in the world-readable Nix store.
            Use `passwordFile` or `passwordCommand` for better security.
            Mutually exclusive with `passwordFile` and `passwordCommand`.
          '';
        };

        passwordFile = lib.mkOption {
          type = with lib.types; nullOr str;
          default = cfg.defaults.passwordFile;
          description = ''
            Path to a file containing the password or API token secret.
            The service will set the `PBS_PASSWORD_FILE` environment variable.
            Mutually exclusive with `password` and `passwordCommand`.
          '';
          example = "/run/keys/pbs-password";
        };

        passwordCommand = lib.mkOption {
          type = with lib.types; nullOr str;
          default = cfg.defaults.passwordCommand;
          description = ''
            A shell command that prints the password or API token secret to stdout.
            The service will set the `PBS_PASSWORD_CMD` environment variable.
            Mutually exclusive with `password` and `passwordFile`.
          '';
          example = "cat /run/keys/pbs-password";
        };

        fingerprint = lib.mkOption {
          type = with lib.types; nullOr str;
          default = cfg.defaults.fingerprint;
          description = ''
            The server's certificate fingerprint for verification, if not using a trusted CA.
            The service will set the `PBS_FINGERPRINT` environment variable.
          '';
          example = "0c:ac:d8:52:67:3a:4a:d5:67:96:2a:83:8e:f1:ac:73:03:f1:d6:9a:4f:9c:86:23:87:a6:31:6c:47:a4:31:b7";
        };

        proxy = lib.mkOption {
          type = with lib.types; nullOr str;
          default = cfg.defaults.proxy;
          description = ''
            HTTP proxy to use for all connections. Sets the ALL_PROXY environment variable.
            Format: `[http://][user:password@]<host>[:port]`
          '';
          example = "http://proxy.example.com:1080";
        };

        calendar = lib.mkOption {
          type = with lib.types; nullOr (either str (listOf str));
          default = "daily";
          description = ''
            When or how often the job should run.
            Must be in a format recognized by `OnCalendar` in systemd.time(7).
            Set to `null` to disable the timer and only allow manual runs.
          '';
          example = "*-*-* 02:00:00";
        };

        persistentTimer = lib.mkEnableOption "persistent systemd timer" // {
          default = cfg.defaults.persistentTimer;
          description = "Run the job immediately after boot if a scheduled run was missed.";
        };

        inhibitsSleep = lib.mkEnableOption "systemd sleep inhibitor" // {
          default = cfg.defaults.inhibitsSleep;
          description = "Prevent the system from sleeping while this job is running.";
        };

        user = lib.mkOption {
          type = lib.types.str;
          default = cfg.defaults.user;
          description = "The user to run the backup client as.";
        };

        group = lib.mkOption {
          type = lib.types.str;
          default = cfg.defaults.group;
          description = "The group to run the backup client as.";
        };

        preHook = lib.mkOption {
          type = lib.types.lines;
          default = cfg.defaults.preHook;
          description = "Shell commands to run before the job starts.";
        };

        postHook = lib.mkOption {
          type = lib.types.lines;
          default = cfg.defaults.postHook;
          description = "Shell commands to run after the job finishes, regardless of success or failure.";
        };
      };
    };

in
{
  meta.maintainers = with lib.maintainers; [ ];

  options.services.nstdl.proxmox-backup = {
    enable = lib.mkEnableOption "Proxmox Backup Client jobs";

    package = lib.mkPackageOption pkgs "proxmox-backup-client" { };

    defaults = lib.mkOption {
      description = "Global default settings for all jobs. These can be overridden on a per-job basis.";
      default = { };
      type = lib.types.submodule {
        options = {
          repository = lib.mkOption {
            type = with lib.types; nullOr str;
            default = null;
            description = "Default `repository` for all jobs.";
          };
          password = lib.mkOption {
            type = with lib.types; nullOr str;
            default = null;
            description = "Default `password` for all jobs. Insecure, use `passwordFile` or `passwordCommand`.";
          };
          passwordFile = lib.mkOption {
            type = with lib.types; nullOr str;
            default = null;
            description = "Default `passwordFile` for all jobs.";
          };
          passwordCommand = lib.mkOption {
            type = with lib.types; nullOr str;
            default = null;
            description = "Default `passwordCommand` for all jobs.";
          };
          fingerprint = lib.mkOption {
            type = with lib.types; nullOr str;
            default = null;
            description = "Default server `fingerprint` for all jobs.";
          };
          proxy = lib.mkOption {
            type = with lib.types; nullOr str;
            default = null;
            description = "Default HTTP `proxy` for all jobs.";
          };
          user = lib.mkOption {
            type = lib.types.str;
            default = "root";
            description = "Default `user` to run jobs as.";
          };
          group = lib.mkOption {
            type = lib.types.str;
            default = "root";
            description = "Default `group` to run jobs as.";
          };
          inhibitsSleep = lib.mkEnableOption "systemd sleep inhibitor for jobs" // {
            default = true;
          };
          namespace = lib.mkOption {
            type = with lib.types; nullOr str;
            default = null;
            description = "Default backup `namespace` for jobs.";
          };
          persistentTimer = lib.mkEnableOption "persistent systemd timer for jobs" // {
            default = true;
            description = "Default `persistentTimer` setting for jobs.";
          };
          changeDetectionMode = lib.mkOption {
            type =
              with lib.types;
              nullOr (enum [
                "legacy"
                "data"
                "metadata"
              ]);
            default = "data";
            description = "Default `changeDetectionMode` for backup jobs.";
          };
          exclude = lib.mkOption {
            type = with lib.types; listOf str;
            default = [ ];
            description = "Default list of `exclude` paths for backup jobs.";
          };
          extraBackupArgs = lib.mkOption {
            type = with lib.types; listOf str;
            default = [ ];
            description = "Default `extraBackupArgs` for backup jobs.";
          };
          extraGcArgs = lib.mkOption {
            type = with lib.types; listOf str;
            default = [ ];
            description = "Default `extraGcArgs` for garbage collection jobs.";
          };
          preHook = lib.mkOption {
            type = lib.types.lines;
            default = "";
            description = "Default `preHook` for jobs.";
          };
          postHook = lib.mkOption {
            type = lib.types.lines;
            default = "";
            description = "Default `postHook` for jobs.";
          };
          prune = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enable = lib.mkEnableOption "pruning for jobs";
                keep = lib.mkOption {
                  type = with lib.types; attrsOf int;
                  default = { };
                  description = "Default `keep` policy for pruning.";
                };
                extraArgs = lib.mkOption {
                  type = with lib.types; listOf str;
                  default = [ ];
                  description = "Default `extraArgs` for jobs.";
                };
              };
            };
            default = { };
            description = "Default `prune` configuration for jobs.";
          };
        };
      };
    };

    jobs = lib.mkOption {
      description = "Declarative Proxmox Backup Client jobs.";
      default = { };
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, config, ... }:
          {
            imports = [ (commonJobOptions { inherit name; }) ];
            options = {
              paths = lib.mkOption {
                type = with lib.types; listOf str;
                description = ''
                  A list of backup specifications. Each entry defines an archive to create.
                  Format: `<archive-name>.<type>:<source-path>`
                '';
                example = [
                  "root.pxar:/"
                  "data.img:/dev/vda"
                ];
              };

              namespace = lib.mkOption {
                type = with lib.types; nullOr str;
                default = cfg.defaults.namespace;
                description = "Organize backups into a specific namespace on the server.";
                example = "vps/webserver";
              };

              backupType = lib.mkOption {
                type =
                  with lib.types;
                  nullOr (enum [
                    "host"
                    "ct"
                    "vm"
                  ]);
                default = null;
                description = ''
                  The type of the backup (`host`, `ct`, or `vm`).
                  This, together with `backupId`, forms the backup group.
                  If not set, the client defaults to `host`.
                '';
                example = "vm";
              };

              backupId = lib.mkOption {
                type = with lib.types; nullOr str;
                default = globalConfig.networking.fqdnOrHostName;
                description = ''
                  The ID of the backup, for example a hostname or a VM ID.
                  This, together with `backupType`, forms the backup group.
                  If not set, the client defaults to the machines fqdn or hostname.
                  This allows you to override the default group, e.g., to create a `vm/101` backup from within a guest.
                '';
                example = "101";
              };

              changeDetectionMode = lib.mkOption {
                type =
                  with lib.types;
                  nullOr (enum [
                    "legacy"
                    "data"
                    "metadata"
                  ]);
                default = cfg.defaults.changeDetectionMode;
                description = ''
                  The change detection mode for file-based backups, to improve performance
                  by avoiding re-reading unchanged files. If null, the client's default is used.
                '';
              };

              exclude = lib.mkOption {
                type = with lib.types; listOf str;
                default = cfg.defaults.exclude;
                description = "List of paths to exclude from file archives (`.pxar`).";
                example = [
                  "/var/cache"
                  "/tmp"
                ];
              };

              encryptionKey = lib.mkOption {
                type = lib.types.submodule {
                  options = {
                    keyFile = lib.mkOption {
                      type = with lib.types; nullOr str;
                      default = null;
                      description = "Path to the client-side encryption key file.";
                      example = "/path/to/my-backup.key";
                    };
                    password = lib.mkOption {
                      type = with lib.types; nullOr str;
                      default = null;
                      description = ''
                        The password for the encryption key. Insecure, use `passwordFile` or `passwordCommand`.
                        Mutually exclusive with `passwordFile` and `passwordCommand`.
                      '';
                    };
                    passwordFile = lib.mkOption {
                      type = with lib.types; nullOr str;
                      default = null;
                      description = ''
                        Path to a file containing the encryption key password. Sets `PBS_ENCRYPTION_PASSWORD_FILE`.
                        Mutually exclusive with `password` and `passwordCommand`.
                      '';
                    };
                    passwordCommand = lib.mkOption {
                      type = with lib.types; nullOr str;
                      default = null;
                      description = ''
                        Command that prints the encryption key password to stdout. Sets `PBS_ENCRYPTION_PASSWORD_CMD`.
                        Mutually exclusive with `password` and `passwordCommand`.
                      '';
                    };
                  };
                };
                default = { };
                description = "Configuration for client-side encryption.";
              };

              prune = lib.mkOption {
                type = lib.types.submodule {
                  options = {
                    enable = lib.mkEnableOption "pruning after backup" // {
                      default = cfg.defaults.prune.enable;
                    };
                    group = lib.mkOption {
                      type = lib.types.str;
                      default =
                        let
                          backupType = if config.backupType != null then config.backupType else "host";
                          backupId =
                            if config.backupId != null then config.backupId else globalConfig.networking.fqdnOrHostName;
                          baseGroup = "${backupType}/${backupId}";
                        in
                        (lib.optionalString (config.namespace != null) "${config.namespace}/") + baseGroup;
                      defaultText = lib.literalExpression ''
                        The backup group to prune. Defaults to a string constructed from `namespace`, `backupType`, and `backupId`.
                        The format is `[<namespace>/]<backupType>/<backupId>`.
                        - `backupType` defaults to `host`.
                        - `backupId` defaults to the system's fqdn or hostname (`config.networking.fqdnOrHostName`).
                      '';
                      description = ''
                        The backup group to prune. This should match the group created by the backup command.
                        The default value is automatically derived from the `backupType`, `backupId`, and `namespace` options.
                      '';
                    };
                    keep = lib.mkOption {
                      type = with lib.types; attrsOf int;
                      default = cfg.defaults.prune.keep;
                      description = ''
                        A set of retention options for pruning, corresponding to the
                        `--keep-*` command-line flags. See the Proxmox Backup documentation
                        for details on how these options interact.
                        Keys can be: `last`, `hourly`, `daily`, `weekly`, `monthly`, `yearly`.
                      '';
                      example = {
                        daily = 7;
                        weekly = 4;
                        monthly = 6;
                        yearly = -1; # keep all yearly backups forever
                      };
                    };
                    extraArgs = lib.mkOption {
                      type = with lib.types; listOf str;
                      default = cfg.defaults.prune.extraArgs;
                      description = "Extra command-line arguments to pass to `proxmox-backup-client prune`.";
                    };
                  };
                };
                default = { };
                description = "Configuration for pruning old backups after a successful new backup.";
                example = {
                  enable = true;
                  keep = {
                    daily = 7;
                    weekly = 4;
                    monthly = 6;
                    yearly = 1;
                  };
                };
              };

              extraBackupArgs = lib.mkOption {
                type = with lib.types; listOf str;
                default = cfg.defaults.extraBackupArgs;
                description = "Extra command-line arguments to pass to `proxmox-backup-client backup`.";
              };
            };
          }
        )
      );
    };

    gcJobs = lib.mkOption {
      description = "Declarative Proxmox Backup Client garbage collection jobs.";
      default = { };
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            imports = [ (commonJobOptions { inherit name; }) ];
            options = {
              extraGcArgs = lib.mkOption {
                type = with lib.types; listOf str;
                default = cfg.defaults.extraGcArgs;
                description = "Extra command-line arguments to pass to `proxmox-backup-client garbage-collect`.";
              };
            };
          }
        )
      );
    };
  };

  config = lib.mkIf cfg.enable (
    let
      # Filter for enabled jobs
      enabledJobs = lib.filterAttrs (_: job: job.enable) cfg.jobs;
      enabledGcJobs = lib.filterAttrs (_: job: job.enable) cfg.gcJobs;

      # Combine enabled backup and gc jobs into a single attrset for unified processing
      allEnabledJobs =
        (lib.mapAttrs (name: job: job // { _type = "backup"; }) enabledJobs)
        // (lib.mapAttrs (name: job: job // { _type = "gc"; }) enabledGcJobs);
    in
    lib.mkIf (allEnabledJobs != { }) {
      assertions =
        # Common assertions for all job types
        (lib.mapAttrsToList (name: job: {
          assertion = job.repository != null;
          message = "proxmox-backup.${job._type}Jobs.${name}: `repository` must be set, either globally or for the job.";
        }) allEnabledJobs)
        ++ (lib.mapAttrsToList (name: job: {
          assertion =
            lib.count (x: x != null) [
              job.password
              job.passwordFile
              job.passwordCommand
            ] <= 1;
          message = "proxmox-backup.${job._type}Jobs.${name}: Only one of password, passwordFile, or passwordCommand can be set.";
        }) allEnabledJobs)
        # Backup-job specific assertions
        ++ (lib.mapAttrsToList (name: job: {
          assertion =
            lib.count (x: x != null) (
              with job.encryptionKey;
              [
                password
                passwordFile
                passwordCommand
              ]
            ) <= 1;
          message = "proxmox-backup.jobs.${name}.encryptionKey: Only one of password, passwordFile, or passwordCommand can be set.";
        }) enabledJobs)
        ++ (lib.mapAttrsToList (name: job: {
          assertion = !(job.prune.enable && job.prune.keep == { });
          message = "proxmox-backup.jobs.${name}: Pruning is enabled but no `keep` options are set. This would delete all backups in the group. Please specify retention options.";
        }) enabledJobs)
        ++ (lib.mapAttrsToList (name: job: {
          assertion = job.paths != [ ];
          message = "proxmox-backup.jobs.${name}: The `paths` option cannot be empty for a backup job.";
        }) enabledJobs);

      systemd.services = lib.mapAttrs' (
        name: job:
        lib.nameValuePair "proxmox-backup-${job._type}-${name}" (mkSystemdJob job._type name job).service
      ) allEnabledJobs;

      systemd.timers = lib.mapAttrs' (
        name: job:
        lib.nameValuePair "proxmox-backup-${job._type}-${name}" (mkSystemdJob job._type name job).timer
      ) (lib.filterAttrs (_: j: j.calendar != null) allEnabledJobs);
    }
  );
}
