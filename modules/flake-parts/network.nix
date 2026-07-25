{ lib, ... }:
let
  inherit (lib) mkOption types;

  hostOption = mkOption {
    type = types.nullOr (
      types.submodule {
        options = {
          interface = mkOption { type = types.nonEmptyStr; };
          addresses = mkOption {
            type = types.listOf (types.strMatching "^[0-9A-Fa-f:.]+/[0-9]+$");
          };
          gateways = mkOption {
            type = types.listOf (types.strMatching "^[0-9A-Fa-f:.]+$");
            default = [ ];
          };
          dns = mkOption {
            type = types.listOf (types.strMatching "^[0-9A-Fa-f:.]+$");
            default = [ ];
          };
        };
      }
    );
    default = null;
    description = "Optional single-interface static systemd-networkd configuration.";
  };

  moduleFor =
    host:
    if host.network != null then
      {
        networking.useNetworkd = true;
        systemd.network = {
          enable = true;
          networks."10-nstdl" = {
            matchConfig.Name = host.network.interface;
            networkConfig = {
              DHCP = "no";
              Address = host.network.addresses;
              Gateway = host.network.gateways;
              DNS = host.network.dns;
            };
          };
        };
      }
    else
      { };

  validateHost =
    name: host:
    if host.platform != "nixos" && host.network != null then
      throw "nstdl static networking is supported only for NixOS hosts"
    else
      true;
in
{
  config._module.args.nstdlNetwork = {
    inherit hostOption moduleFor validateHost;
  };
}
