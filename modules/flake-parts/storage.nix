{ lib, ... }:
let
  inherit (lib) mkOption types;

  hostOption = mkOption {
    type = types.nullOr (
      types.submodule {
        options = {
          device = mkOption {
            type = types.str;
            description = "Single disk device used for the standard EFI and Btrfs layout.";
          };
          encryption = mkOption {
            type = types.enum [
              "none"
              "luks"
            ];
            description = "Whether the standard Btrfs volume is protected by LUKS.";
          };
          espSize = mkOption {
            type = types.str;
            default = "1G";
            description = "EFI System Partition size.";
          };
          snapshots = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = "Create local Btrfs snapshots with btrbk.";
            };
            calendar = mkOption {
              type = types.str;
              default = "hourly";
              description = "systemd calendar expression for local snapshots.";
            };
            hourly = mkOption {
              type = types.positive;
              default = 72;
              description = "Hourly snapshots retained by btrbk.";
            };
            daily = mkOption {
              type = types.positive;
              default = 14;
              description = "Daily snapshots retained by btrbk.";
            };
            weekly = mkOption {
              type = types.positive;
              default = 4;
              description = "Weekly snapshots retained by btrbk.";
            };
          };
        };
      }
    );
    default = null;
    description = "Optional standard single-disk EFI, Btrfs, and local-snapshot layout.";
  };

  moduleFor =
    host:
    if host.storage != null then
      let
        storage = host.storage;
        btrfsContent = {
          type = "btrfs";
          mountpoint = "/mnt/btrfs-roots/main";
          mountOptions = [ "compress=zstd" ];
          subvolumes = {
            "/@root" = {
              mountpoint = "/";
              mountOptions = [ "compress=zstd" ];
            };
            "/@home" = {
              mountpoint = "/home";
              mountOptions = [ "compress=zstd" ];
            };
            "/@nix" = {
              mountpoint = "/nix";
              mountOptions = [
                "compress=zstd"
                "noatime"
              ];
            };
            "/@var" = {
              mountpoint = "/var";
              mountOptions = [ "compress=zstd" ];
            };
            "/@snapshots" = { };
          };
        };
        mainContent =
          if storage.encryption == "luks" then
            {
              type = "luks";
              name = "luks-main";
              settings.allowDiscards = true;
              content = btrfsContent;
            }
          else
            btrfsContent;
      in
      {
        disko.devices.disk.main = {
          type = "disk";
          device = storage.device;
          content = {
            type = "gpt";
            partitions = {
              esp = {
                priority = 1;
                size = storage.espSize;
                type = "EF00";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                  mountOptions = [ "umask=0077" ];
                };
              };
              main = {
                size = "100%";
                content = mainContent;
              };
            };
          };
        };
        services =
          lib.optionalAttrs storage.snapshots.enable {
            btrbk.instances.nstdl = {
              onCalendar = storage.snapshots.calendar;
              settings = {
                incremental = "no";
                snapshot_create = "always";
                snapshot_preserve = "${toString storage.snapshots.hourly}h ${toString storage.snapshots.daily}d ${toString storage.snapshots.weekly}w";
                volume."/mnt/btrfs-roots/main" = {
                  snapshot_dir = "@snapshots";
                  subvolume = {
                    "@root" = { };
                    "@home" = { };
                    "@var" = { };
                  };
                };
              };
            };
          }
          // {
            btrfs.autoScrub = {
              enable = true;
              interval = "monthly";
              fileSystems = [ "/" ];
            };
          };
      }
    else
      { };

  importsFor = inputs: host: lib.optional (host.storage != null) inputs.disko.nixosModules.disko;

  validateHost =
    name: host:
    if host.platform != "nixos" && host.storage != null then
      throw "nstdl standard storage is supported only for NixOS hosts"
    else
      true;
in
{
  config._module.args.nstdlStorage = {
    inherit
      hostOption
      importsFor
      moduleFor
      validateHost
      ;
  };
}
