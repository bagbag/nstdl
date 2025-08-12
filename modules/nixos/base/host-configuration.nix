{
  lib,
  config,
  ...
}:
{
  options.nstdl.hostConfig = {
    deploy = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to deploy this host.";
      default = true;
    };
    environment = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "The environment this host is part of. This can be used to load environment-specific configurations.";
    };
    virtualisation = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "The virtualisation technology used for this host (e.g. qemu, vmware).";
      default = null;
    };
    hostname = lib.mkOption {
      type = lib.types.str;
      description = "The hostname of the machine.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = null;
      description = "The domain of the machine.";
    };
    interface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "The network interface to use for the static IP configuration.";
    };
    host = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "The host to connect to for this machine, defaults to the IPv6 or IPv4 address if not set.";
    };
    ipv4 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "The static IPv4 address (with CIDR) of the machine.";
      default = null;
    };
    ipv4Address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "The IPv4 address (without CIDR) of the machine.";
      default = null;
    };
    gateway4 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "The gateway for the static IPv4 address.";
      default = null;
    };
    ipv6 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "The static IPv6 address (with CIDR) of the machine.";
      default = null;
    };
    ipv6Address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "The IPv6 address (without CIDR) of the machine.";
      default = null;
    };
    gateway6 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "The gateway for the static IPv6 address.";
      default = null;
    };
    dns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "1.1.1.1"
        "8.8.8.8"
        "2606:4700:4700::1111"
        "2001:4860:4860::8888"
      ];
    };
  };
}
