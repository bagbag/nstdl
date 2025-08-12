{
  lib,
  hostConfig,
  ...
}:
{
  networking.hostName = hostConfig.hostname;
  networking.domain = hostConfig.domain;
  networking.useNetworkd = true;

  systemd.network = {
    enable = true;
    networks = {
      "10-lan" = {
        matchConfig = {
          Name = hostConfig.interface;
        };
        networkConfig = {
          Address = lib.filter (v: v != null) [
            hostConfig.ipv4
            hostConfig.ipv6
          ];

          Gateway = lib.filter (v: v != null) [
            hostConfig.gateway4
            hostConfig.gateway6
          ];

          DNS = hostConfig.dns;
        };
      };
    };
  };
}
