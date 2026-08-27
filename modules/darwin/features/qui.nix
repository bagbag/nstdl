{ config, lib, pkgs, ... }:
{
  assertions = [
    {
      assertion = config.nstdl.user.name != null;
      message = "nstdl qui requires a primary user.";
    }
  ];

  config = lib.mkIf (config.nstdl.user.name != null) (
    let
      userHome = config.users.users.${config.nstdl.user.name}.home;
      configDir = "${userHome}/.config/qui";
      configDirArg = lib.escapeShellArg configDir;
      launcher = pkgs.writeShellScript "nstdl-qui-launcher" ''
        set -eu

        config_dir=${configDirArg}
        secret_file="$config_dir/session-secret"
        ${pkgs.coreutils}/bin/mkdir -p "$config_dir"

        if [ ! -s "$secret_file" ]; then
          umask 077
          ${pkgs.openssl}/bin/openssl rand -hex 32 > "$secret_file"
        fi
        ${pkgs.coreutils}/bin/chmod 600 "$secret_file"

        export QUI__SESSION_SECRET_FILE="$secret_file"
        exec ${pkgs.qui}/bin/qui serve --config-dir "$config_dir"
      '';
    in
    {
      environment.systemPackages = [ pkgs.qui ];

      launchd.user.agents.qui.serviceConfig = {
        ProgramArguments = [ launcher ];
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "${userHome}/Library/Logs/qui.log";
        StandardErrorPath = "${userHome}/Library/Logs/qui.log";
      };
    }
  );
}
