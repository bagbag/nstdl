{
  lib,
  config,
  ...
}:
let
  hasDomain = config.nstdl.hostConfig.domain != null;
in
{
  networking.hostName = config.nstdl.hostConfig.hostname;
  networking.domain = lib.mkIf hasDomain config.nstdl.hostConfig.domain;

  networking.useNetworkd = true;

  systemd.network = {
    enable = true;
    networks = {
      "10-lan" = {
        matchConfig = {
          Name = config.nstdl.hostConfig.interface;
        };
        networkConfig = {
          Address = lib.filter (v: v != null) [
            config.nstdl.hostConfig.ipv4
            config.nstdl.hostConfig.ipv6
          ];

          Gateway = lib.filter (v: v != null) [
            config.nstdl.hostConfig.gateway4
            config.nstdl.hostConfig.gateway6
          ];

          DNS = config.nstdl.hostConfig.dns;
        };
      };
    };
  };
}
