{
  virtualisation = {
    containers = {
      enable = true;
      registries.settings.registries.search.registries = [
        "docker.io"
        "quay.io"
      ];
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
