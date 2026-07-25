{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nstdl.proxmoxBackup;
  enabledJobs = lib.filterAttrs (_: job: job.enable) cfg.jobs;
  retentionType = lib.types.addCheck (lib.types.attrsOf (lib.types.ints.between 1 2147483647)) (
    keep:
    lib.all (
      name:
      lib.elem name [
        "last"
        "hourly"
        "daily"
        "weekly"
        "monthly"
        "yearly"
      ]
    ) (lib.attrNames keep)
  );
  chunkSizeType = lib.types.addCheck (lib.types.ints.between 64 4096) (
    size:
    lib.elem size [
      64
      128
      256
      512
      1024
      2048
      4096
    ]
  );
  runtimePathType = lib.types.addCheck lib.types.nonEmptyStr (
    path: lib.hasPrefix "/" path && !builtins.hasContext path
  );
  archiveType = lib.types.coercedTo lib.types.str (source: { inherit source; }) (
    lib.types.submodule {
      options = {
        type = lib.mkOption {
          type = lib.types.enum [
            "pxar"
            "img"
            "conf"
            "log"
          ];
          default = "pxar";
          description = "PBS archive type.";
        };
        source = lib.mkOption {
          type = lib.types.str;
          description = "Absolute runtime path passed to proxmox-backup-client.";
        };
      };
    }
  );
  archiveSetType = lib.types.addCheck (lib.types.attrsOf archiveType) (
    archives: lib.all (name: builtins.match "^[A-Za-z0-9_-]+$" name != null) (lib.attrNames archives)
  );
  enabled = flag: condition: lib.optional condition flag;
  value =
    flag: option:
    lib.optionals (option != null) [
      flag
      (toString option)
    ];
  shellEscape = string: "'${lib.replaceStrings [ "'" ] [ "'\\''" ] (toString string)}'";
  shellArgs = arguments: lib.concatStringsSep " " (map shellEscape arguments);
  credentialProperties =
    job:
    [
      "LoadCredential=proxmox-backup-client.password:${toString job.passwordFile}"
      "SetCredential=proxmox-backup-client.repository:${job.repository}"
    ]
    ++ lib.optional (
      job.fingerprint != null
    ) "SetCredential=proxmox-backup-client.fingerprint:${job.fingerprint}"
    ++
      lib.optional (job.encryption.passwordFile != null)
        "LoadCredential=proxmox-backup-client.encryption-password:${toString job.encryption.passwordFile}";
  backupArgs =
    job:
    lib.mapAttrsToList (
      name: archive: "${name}.${archive.type}:${toString archive.source}"
    ) job.archives
    ++ value "--backup-type" job.backupType
    ++ value "--backup-id" job.backupId
    ++ value "--backup-time" job.backupTime
    ++ value "--ns" job.namespace
    ++ value "--change-detection-mode" job.changeDetectionMode
    ++ value "--chunk-size" job.chunkSize
    ++ value "--entries-max" job.entriesMax
    ++ value "--rate" job.rate
    ++ value "--burst" job.burst
    ++ value "--keyfile" job.encryption.keyFile
    ++ value "--master-pubkey-file" job.encryption.masterPublicKeyFile
    ++ lib.concatMap (path: [
      "--exclude"
      path
    ]) job.excludes
    ++ lib.concatMap (path: [
      "--include-dev"
      path
    ]) job.includeDev
    ++ enabled "--all-file-systems" job.allFileSystems
    ++ enabled "--dry-run" job.dryRun
    ++ enabled "--no-cache" job.noCache
    ++ enabled "--skip-e2big-xattr" job.skipE2bigXattr
    ++ enabled "--skip-lost-and-found" job.skipLostAndFound
    ++ value "--crypt-mode" job.encryption.cryptMode;
  pruneArgs =
    job:
    [ (if job.prune.group != null then job.prune.group else "${job.backupType}/${job.backupId}") ]
    ++ lib.mapAttrsToList (name: count: "--keep-${name}=${toString count}") job.prune.keep
    ++ value "--ns" job.namespace
    ++ value "--max-depth" job.prune.maxDepth
    ++ value "--output-format" job.prune.outputFormat
    ++ enabled "--dry-run" job.prune.dryRun
    ++ enabled "--quiet" job.prune.quiet;
  mkWrapper =
    name: job:
    pkgs.writeShellScriptBin "proxmox-backup-client-${name}" ''
      if [[ "''${1-}" == "garbage-collect" ]]; then
        echo "client-side garbage collection is intentionally unsupported; schedule it on the PBS server" >&2
        exit 2
      fi
      command="''${1-}"
      subcommand="''${2-}"

      hasArgument() {
        local flag="$1"
        shift
        local argument
        for argument in "$@"; do
          if [[ "$argument" == "$flag" || "$argument" == "$flag="* ]]; then
            return 0
          fi
        done
        return 1
      }

      ${lib.optionalString (job.namespace != null) ''
        case "$command" in
          backup|catalog|change-owner|group|list|map|mount|prune|restore|snapshot)
            if ! hasArgument --ns "$@"; then
              set -- "$@" --ns ${shellEscape job.namespace}
            fi
            ;;
        esac
      ''}
      ${lib.optionalString (job.encryption.keyFile != null) ''
        case "$command" in
          backup|benchmark|catalog|map|mount|restore)
            if ! hasArgument --keyfile "$@" && ! hasArgument --keyfd "$@"; then
              set -- "$@" --keyfile ${shellEscape job.encryption.keyFile}
            fi
            ;;
          snapshot)
            if [[ "$subcommand" == "upload-log" ]] && ! hasArgument --keyfile "$@" && ! hasArgument --keyfd "$@"; then
              set -- "$@" --keyfile ${shellEscape job.encryption.keyFile}
            fi
            ;;
        esac
      ''}
      exec ${pkgs.systemd}/bin/systemd-run --quiet --pipe --wait --collect ${
        shellArgs (map (property: "--property=${property}") (credentialProperties job))
      } --same-dir -- ${pkgs.proxmox-backup-client}/bin/proxmox-backup-client "$@"
    '';
in
{
  options.services.nstdl.proxmoxBackup = {
    enable = lib.mkEnableOption "nstdl Proxmox Backup Client jobs";
    defaults = {
      user = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        description = "System user for jobs unless overridden.";
      };
      group = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        description = "System group for jobs unless overridden.";
      };
      namespace = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "PBS namespace for jobs unless overridden.";
      };
      calendar = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "daily";
        description = "Timer schedule for jobs unless overridden.";
      };
      persistent = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Persistent timer behavior for jobs unless overridden.";
      };
      changeDetectionMode = lib.mkOption {
        type = lib.types.enum [
          "legacy"
          "data"
          "metadata"
        ];
        default = "data";
        description = "Backup change detection default.";
      };
      excludes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Backup exclusions for jobs unless overridden.";
      };
    };
    defaults.prune.keep = lib.mkOption {
      type = retentionType;
      default = { };
      description = "Retention applied to jobs unless the job overrides it. An empty set skips pruning and retains every snapshot.";
    };
    jobs = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }: {
            options = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
              };
              repository = lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "PBS repository including an API-token identity, for example user@realm!token@host:datastore.";
              };
              passwordFile = lib.mkOption {
                type = runtimePathType;
                description = "Path containing the PBS API-token secret. It is loaded as a systemd credential, never placed in the unit.";
              };
              fingerprint = lib.mkOption {
                type = lib.types.nullOr lib.types.nonEmptyStr;
                default = null;
                description = "Pinned PBS TLS certificate fingerprint.";
              };
              trustedCa = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Allow normal CA validation instead of pinning fingerprint.";
              };
              calendar = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = cfg.defaults.calendar;
                description = "systemd OnCalendar expression, or null to create only a manually runnable service.";
              };
              persistent = lib.mkOption {
                type = lib.types.bool;
                default = cfg.defaults.persistent;
                description = "Run a missed scheduled backup after boot.";
              };
              archives = lib.mkOption {
                default = { };
                type = archiveSetType;
                description = "Explicit client archive specifications, keyed by archive name.";
              };
              namespace = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = cfg.defaults.namespace;
                description = "Optional PBS namespace.";
              };
              backupType = lib.mkOption {
                type = lib.types.enum [
                  "host"
                  "ct"
                  "vm"
                ];
                default = "host";
                description = "PBS backup group type.";
              };
              backupId = lib.mkOption {
                type = lib.types.nonEmptyStr;
                default = config.networking.hostName;
                description = "PBS backup group ID.";
              };
              backupTime = lib.mkOption {
                type = lib.types.nullOr lib.types.ints.positive;
                default = null;
                description = "Unix timestamp sent as --backup-time.";
              };
              allFileSystems = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Pass --all-file-systems.";
              };
              changeDetectionMode = lib.mkOption {
                type = lib.types.enum [
                  "legacy"
                  "data"
                  "metadata"
                ];
                default = cfg.defaults.changeDetectionMode;
                description = "PBS change-detection mode.";
              };
              chunkSize = lib.mkOption {
                type = chunkSizeType;
                default = 4096;
                description = "Maximum chunk size in KiB.";
              };
              entriesMax = lib.mkOption {
                type = lib.types.ints.unsigned;
                default = 1048576;
                description = "Maximum backup index entries.";
              };
              excludes = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = cfg.defaults.excludes;
                description = "Paths excluded with --exclude.";
              };
              includeDev = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Paths explicitly included with --include-dev.";
              };
              rate = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Optional backup rate limit.";
              };
              burst = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Optional backup burst limit.";
              };
              dryRun = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Pass --dry-run to backup.";
              };
              noCache = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Pass --no-cache to backup.";
              };
              skipE2bigXattr = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Pass --skip-e2big-xattr to backup.";
              };
              skipLostAndFound = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Pass --skip-lost-and-found to backup.";
              };
              user = lib.mkOption {
                type = lib.types.nullOr lib.types.nonEmptyStr;
                default = cfg.defaults.user;
                description = "System user running this job; null uses root.";
              };
              group = lib.mkOption {
                type = lib.types.nullOr lib.types.nonEmptyStr;
                default = cfg.defaults.group;
                description = "System group running this job; null uses the selected user's primary group.";
              };
              encryption = {
                keyFile = lib.mkOption {
                  type = lib.types.nullOr runtimePathType;
                  default = null;
                  description = "Encryption key file passed as --keyfile.";
                };
                passwordFile = lib.mkOption {
                  type = lib.types.nullOr runtimePathType;
                  default = null;
                  description = "Optional encryption-key password, loaded as a systemd credential.";
                };
                masterPublicKeyFile = lib.mkOption {
                  type = lib.types.nullOr runtimePathType;
                  default = null;
                  description = "Optional master public key passed as --master-pubkey-file.";
                };
                cryptMode = lib.mkOption {
                  type = lib.types.enum [
                    "none"
                    "encrypt"
                    "sign-only"
                  ];
                  default = "none";
                  description = "PBS encryption mode.";
                };
              };
              prune = {
                group = lib.mkOption {
                  type = lib.types.nullOr lib.types.nonEmptyStr;
                  default = null;
                  description = "Backup group to prune; defaults to this job's type/id.";
                };
                keep = lib.mkOption {
                  type = retentionType;
                  default = cfg.defaults.prune.keep;
                  description = "PBS keep-* retention. An empty set skips pruning.";
                };
                maxDepth = lib.mkOption {
                  type = lib.types.nullOr (lib.types.ints.between 0 7);
                  default = null;
                  description = "Optional prune namespace depth.";
                };
                outputFormat = lib.mkOption {
                  type = lib.types.enum [
                    "text"
                    "json"
                    "json-pretty"
                  ];
                  default = "text";
                  description = "Prune output format.";
                };
                dryRun = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Pass --dry-run to prune.";
                };
                quiet = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Pass --quiet to prune.";
                };
              };
            };
          }
        )
      );
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = lib.flatten (
      lib.mapAttrsToList (name: job: [
        {
          assertion = job.trustedCa || job.fingerprint != null;
          message = "proxmoxBackup job '${name}' requires fingerprint unless trustedCa is enabled.";
        }
        {
          assertion = job.archives != { };
          message = "proxmoxBackup job '${name}' requires at least one archive.";
        }
        {
          assertion = builtins.match ".*!.*@.*" job.repository != null;
          message = "proxmoxBackup job '${name}' repository must use an API-token auth ID.";
        }
        {
          assertion = lib.all (archive: lib.hasPrefix "/" archive.source) (lib.attrValues job.archives);
          message = "proxmoxBackup job '${name}' archive sources must be absolute runtime paths.";
        }
        {
          assertion = job.encryption.cryptMode == "none" || job.encryption.keyFile != null;
          message = "proxmoxBackup job '${name}' must set encryption.keyFile when encryption is enabled.";
        }
      ]) enabledJobs
    );
    systemd.services = lib.mapAttrs' (
      name: job:
      lib.nameValuePair "nstdl-proxmox-backup-${name}" {
        description = "nstdl Proxmox Backup job '${name}'";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        path = [ pkgs.proxmox-backup-client ];
        script = ''
          set -euo pipefail
          proxmox-backup-client backup ${shellArgs (backupArgs job)}
          ${lib.optionalString (
            job.prune.keep != { }
          ) "proxmox-backup-client prune ${shellArgs (pruneArgs job)}"}
        '';
        serviceConfig = {
          Type = "oneshot";
          LoadCredential = [
            "proxmox-backup-client.password:${toString job.passwordFile}"
          ]
          ++ lib.optional (
            job.encryption.passwordFile != null
          ) "proxmox-backup-client.encryption-password:${toString job.encryption.passwordFile}";
          SetCredential = [
            "proxmox-backup-client.repository:${job.repository}"
          ]
          ++ lib.optional (job.fingerprint != null) "proxmox-backup-client.fingerprint:${job.fingerprint}";
          ProtectSystem = "strict";
          NoNewPrivileges = true;
        }
        // lib.optionalAttrs (job.user != null) { User = job.user; }
        // lib.optionalAttrs (job.group != null) { Group = job.group; };
      }
    ) enabledJobs;
    systemd.timers = lib.mapAttrs' (
      name: job:
      lib.nameValuePair "nstdl-proxmox-backup-${name}" {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = job.calendar;
          Persistent = job.persistent;
        };
      }
    ) (lib.filterAttrs (_: job: job.calendar != null) enabledJobs);
    environment.systemPackages = lib.mapAttrsToList mkWrapper enabledJobs;
  };
}
