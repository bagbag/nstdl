{
  lib,
  config,
  ...
}:
{
  networking.hostName = config.hostConfig.hostname;
  networking.domain = config.hostConfig.domain;
  networking.useNetworkd = true;

  systemd.network = {
    enable = true;
    networks = {
      "10-lan" = {
        matchConfig = {
          Name = config.hostConfig.interface;
        };
        networkConfig = {
          Address = lib.filter (v: v != null) [
            config.hostConfig.ipv4
            config.hostConfig.ipv6
          ];

          Gateway = lib.filter (v: v != null) [
            config.hostConfig.gateway4
            config.hostConfig.gateway6
          ];

          DNS = config.hostConfig.dns;
        };
      };
    };
  };
}
