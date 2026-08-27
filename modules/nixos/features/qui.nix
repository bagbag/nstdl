{ pkgs, ... }:
let
  secretFile = "/var/lib/qui/secret";
in
{
  services.qui = {
    enable = true;
    inherit secretFile;
  };

  systemd.services.qui-secret-generator = {
    description = "Generate session secret for qui";
    wantedBy = [ "multi-user.target" ];
    before = [ "qui.service" ];

    path = [ pkgs.coreutils pkgs.openssl ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      if [ ! -f "${secretFile}" ]; then
        mkdir -p "$(dirname "${secretFile}")"
        openssl rand -hex 32 > "${secretFile}"
        chmod 600 "${secretFile}"
      fi
    '';
  };

  systemd.services.qui = {
    after = [ "qui-secret-generator.service" ];
    requires = [ "qui-secret-generator.service" ];
  };
}
