{ lib, options, ... }:
let
  registryConfiguration =
    if lib.hasAttrByPath [ "virtualisation" "containers" "registries" "settings" ] options then
      {
        settings.registries.search.registries = [
          "docker.io"
          "quay.io"
        ];
      }
    else
      {
        # Compatibility for nixpkgs releases that predate registries.settings.
        search = [
          "docker.io"
          "quay.io"
        ];
      };
in
{
  virtualisation = {
    containers = {
      enable = true;
      registries = registryConfiguration;
      policy = {
        default = [ { type = "reject"; } ];
        transports = {
          docker = {
            "docker.io" = [ { type = "insecureAcceptAnything"; } ];
            "quay.io" = [ { type = "insecureAcceptAnything"; } ];
          };
          docker-daemon."" = [ { type = "insecureAcceptAnything"; } ];
        };
      };
    };

    podman = {
      enable = true;
      defaultNetwork.settings.dns_enabled = true;
    };
  };
}
