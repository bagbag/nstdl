{ pkgs, ... }:
let
  battConfig = pkgs.writeText "batt.json" (builtins.toJSON {
    limit = 70;
    lowerLimitDelta = 5;
    allowNonRootAccess = true;
  });
in
{
  homebrew.brews = [ "batt" ];

  system.activationScripts.nstdlBattConfig.text = ''
    install -d -o root -g wheel -m 0755 /var/db
    install -o root -g wheel -m 0644 ${battConfig} /var/db/batt.json
    launchctl kill -s HUP system/org.nixos.nstdl-batt 2>/dev/null || true
  '';

  launchd.daemons.nstdl-batt.serviceConfig = {
    ProgramArguments = [
      "/opt/homebrew/bin/batt"
      "daemon"
      "--log-level=debug"
      "--always-allow-non-root-access"
      "--config=/var/db/batt.json"
    ];
    KeepAlive = true;
    ProcessType = "Interactive";
    RunAtLoad = true;
    StandardOutPath = "/var/log/batt.log";
    StandardErrorPath = "/var/log/batt.log";
  };
}
