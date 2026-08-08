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

  system.activationScripts.postActivation.text = ''
    install -o root -g wheel -m 0644 ${battConfig} /etc/batt.json
    launchctl kickstart -k system/org.nixos.nstdl-batt
  '';

  launchd.daemons.nstdl-batt.serviceConfig = {
    ProgramArguments = [
      "/opt/homebrew/bin/batt"
      "daemon"
      "--log-level=debug"
      "--always-allow-non-root-access"
    ];
    KeepAlive = true;
    ProcessType = "Interactive";
    RunAtLoad = true;
    StandardOutPath = "/var/log/batt.log";
    StandardErrorPath = "/var/log/batt.log";
  };
}
