{
  lib,
  config,
  ...
}:
{
  options.nstdl.hostConfig = {
    identifier = lib.mkOption {
      type = lib.types.str;
      description = "The unique identifier for this host (matches the attribute name in `hosts`).";
      example = "web-server-01";
    };
    deploy = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to generate a deploy-rs entry for this host.";
      example = false;
    };
    environment = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "The environment this host is part of. Loads configuration from `modules/environments/<name>.nix` if present.";
      example = "production";
    };
    virtualisation = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The virtualisation technology used for this host (e.g., 'qemu', 'vmware') to enable guest agents.";
      example = "qemu";
    };
    disko = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "The disk configuration to load from `modules/disko/<name>.nix`.";
      example = "simple-efi-gpt";
    };
    hostname = lib.mkOption {
      type = lib.types.str;
      description = "The hostname of the machine.";
      example = "web-01";
    };
    domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The domain of the machine.";
      example = "internal.example.com";
    };
    interface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "The primary network interface to use for the static IP configuration.";
      example = "ens18";
    };
    host = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "The connection address (IP or hostname) deploy-rs should use. Defaults to the IPv6 or IPv4 address.";
      example = "10.0.0.50";
    };
    ipv4 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The static IPv4 address of the machine in CIDR notation.";
      example = "192.168.1.10/24";
    };
    ipv4Address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The IPv4 address of the machine (without CIDR suffix). Automatically calculated from `ipv4`.";
      example = "192.168.1.10";
    };
    gateway4 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The gateway for the static IPv4 address.";
      example = "192.168.1.1";
    };
    ipv6 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The static IPv6 address of the machine in CIDR notation.";
      example = "2001:db8::10/64";
    };
    ipv6Address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The IPv6 address of the machine (without CIDR suffix). Automatically calculated from `ipv6`.";
      example = "2001:db8::10";
    };
    gateway6 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The gateway for the static IPv6 address.";
      example = "2001:db8::1";
    };
    dns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "2606:4700:4700::1111"
        "2001:4860:4860::8888"
        "1.1.1.1"
        "8.8.8.8"
      ];
      description = "List of DNS servers to use.";
      example = [ "1.1.1.1" ];
    };
  };
}
