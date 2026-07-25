{ lib, ... }:
let
  inherit (lib) mkOption types;

  hostOptions = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Generate a deploy-rs node for this NixOS host.";
    };
    targetHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "SSH host name or address used by deploy-rs.";
    };
    sshUser = mkOption {
      type = types.str;
      default = "admin";
      description = "SSH user used by deploy-rs.";
    };
    fastConnection = mkOption {
      type = types.bool;
      default = true;
      description = "Whether deploy-rs should reuse a single SSH connection.";
    };
  };

  validateHost =
    name: host:
    if host.platform != "nixos" && host.deployment.enable then
      throw "nstdl deployment is supported only for NixOS hosts"
    else if host.deployment.enable && host.deployment.targetHost == null then
      throw "nstdl deployable host '${name}' must set deployment.targetHost"
    else
      true;

  nodesFor =
    {
      config,
      inputs,
      hosts,
    }:
    lib.mapAttrs (name: host: {
      hostname = host.deployment.targetHost;
      sshUser = host.deployment.sshUser;
      fastConnection = host.deployment.fastConnection;
      profiles.system = {
        user = "root";
        path = inputs.deploy-rs.lib.${host.system}.activate.nixos config.flake.nixosConfigurations.${name};
      };
    }) (lib.filterAttrs (_: host: host.deployment.enable) hosts);

  checksFor =
    {
      deploy,
      inputs,
      system,
    }:
    lib.optionalAttrs (lib.hasSuffix "-linux" system && deploy.nodes != { }) (
      inputs.deploy-rs.lib.${system}.deployChecks deploy
    );
in
{
  config._module.args.nstdlDeployment = {
    inherit
      checksFor
      hostOptions
      nodesFor
      validateHost
      ;
  };
}
