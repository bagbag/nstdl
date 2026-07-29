{
  virtualisation = {
    containers = {
      enable = true;
      registries.search = [
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
