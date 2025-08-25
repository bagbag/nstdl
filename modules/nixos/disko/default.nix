{ config, lib, ... }:
with lib;
let
  cfg = config.nstdl.disko;

  # A helper function to generate the btrfs subvolume config
  # from a list of content names like ["root", "home", ...].
  generateBtrfsSubvolumes =
    contentNames: swapSize:
    let
      # A map from our abstract content names to the concrete disko subvolume definitions.
      subvolumeDefinitions = {
        root = {
          "/@root" = {
            mountpoint = "/";
            mountOptions = [ "compress=zstd" ];
          };
        };
        nix = {
          "/@nix" = {
            mountpoint = "/nix";
            mountOptions = [
              "compress=zstd"
              "noatime"
            ];
          };
        };
        home = {
          "/@home" = {
            mountpoint = "/home";
            mountOptions = [ "compress=zstd" ];
          };
        };
        var = {
          "/@var" = {
            mountpoint = "/var";
            mountOptions = [ "compress=zstd" ];
          };
        };
        data = {
          "/@data" = {
            mountpoint = "/data";
            mountOptions = [ "compress=zstd" ];
          };
        };
        swap = {
          "/@swap" = {
            mountpoint = "/.swapvol";
            swap.swapfile.size = swapSize;
          };
        };
      };
      # Select the definitions based on the user's `content` list.
      selectedSubvolumes = map (name: subvolumeDefinitions.${name}) contentNames;
    in
    # Merge the list of attribute sets into a single one.
    foldl' mergeAttrs { } selectedSubvolumes;

  # Generates the final `disko` configuration for a single disk
  # based on the user's abstract definition.
  generateDiskConfig =
    name: diskCfg:
    let
      # Content types that are implemented as btrfs subvolumes.
      btrfsContentTypes = [
        "root"
        "home"
        "nix"
        "var"
        "swap"
        "data"
      ];
      # The subvolumes requested for *this* specific disk.
      subvolumeNames = intersectLists btrfsContentTypes diskCfg.content;

      # Generate the btrfs part of the config only if there are subvolumes to create.
      filesystemContent =
        if diskCfg.fs == "btrfs" then
          {
            type = "btrfs";
            # mount the btrfs root for easy access when manually troubleshooting or adding new subvolumes
            mountpoint = "/mnt/btrfs-roots/${name}";
            mountOptions = [ "compress=zstd" ];
            subvolumes = generateBtrfsSubvolumes subvolumeNames diskCfg.swapSize;
          }
        else
          {
            # This is where support for other filesystems could be added.
          };

      # Wrap the btrfs content in a LUKS container if encryption is enabled.
      partitionContent =
        if diskCfg.encrypted && filesystemContent != { } then
          {
            type = "luks";
            name = "luks-${name}";
            askPassword = true;
            settings.allowDiscards = true;
            content = filesystemContent;
          }
        else if filesystemContent != { } then
          filesystemContent
        else
          { };

      mainPartition = mkIf (partitionContent != { }) {
        # Using the disk name ensures this partition name is unique.
        "${name}" = {
          size = "100%";
          content = partitionContent;
        };
      };

      bootPartition = mkIf (elem "boot" diskCfg.content) {
        ESP = {
          priority = 1;
          size = diskCfg.bootSize;
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
      };

    in
    {
      type = "disk";
      device = diskCfg.device;
      content = {
        type = "gpt";
        partitions = mergeAttrs bootPartition mainPartition;
      };
    };

in
{
  options.nstdl.disko = {
    enable = mkEnableOption "nstdl declarative disk configuration module";

    disks = mkOption {
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              device = mkOption {
                type = types.str;
                description = "Path to the disk device, e.g. /dev/sda or /dev/disk/by-id/...";
                example = "/dev/vda";
              };

              encrypted = mkOption {
                type = types.bool;
                default = false;
                description = "Whether to encrypt the main data partition with LUKS.";
              };

              fs = mkOption {
                type = types.enum [ "btrfs" ];
                default = "btrfs";
                description = "The filesystem to use for the content (except boot). Currently only 'btrfs' is supported.";
              };

              content = mkOption {
                type = types.listOf (
                  types.enum [
                    "boot"
                    "root"
                    "home"
                    "nix"
                    "var"
                    "swap"
                    "data"
                  ]
                );
                default = [ ];
                description = "A list of components to place on this disk.";
                example = [
                  "boot"
                  "root"
                  "home"
                  "nix"
                  "var"
                  "swap"
                ];
              };

              bootSize = mkOption {
                type = types.str;
                default = "512M";
                description = "Size of the EFI boot partition.";
              };

              swapSize = mkOption {
                type = types.str;
                default = "4G";
                description = "Size of the swap file (if 'swap' is in content).";
              };
            };
          }
        )
      );
      default = { };
      description = "Declarative specification of disk layouts.";
      example = ''
        nstdl.disko.disks = {
          # A single, encrypted disk for a typical laptop/server
          os = {
            device = "/dev/disk/by-id/nvme-eui-....";
            encrypted = true;
            content = [ "boot" "root" "home" "nix" "var" "swap" ];
          };

          # A separate, unencrypted disk for bulk data
          data = {
            device = "/dev/disk/by-id/ata-....";
            content = [ "data" ];
          };
        };
      '';
    };
  };

  config = mkIf cfg.enable {
    disko.devices.disk = mapAttrs generateDiskConfig cfg.disks;
  };
}
