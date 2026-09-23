{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nstdl.programs.pnpm.registryAuth;

  # pnpm reads auth.ini separately from config.yaml, so owning it does not
  # conflict with a managed config.yaml or .npmrc. pnpm prefers
  # $XDG_CONFIG_HOME/pnpm over its platform default.
  useXdg = pkgs.stdenv.isLinux || config.xdg.enable;

  # The trailing slash is significant: pnpm never matches a key without it.
  key =
    registry:
    "//${lib.removeSuffix "/" (lib.removePrefix "https://" (lib.removePrefix "http://" registry))}/";

  # pnpm runs the helper when it needs the token, so the token is never copied
  # out of the secret file and rotation applies on the next pnpm run.
  tokenHelper =
    name: entry:
    pkgs.writeShellScript "nstdl-pnpm-token-${name}" ''
      exec ${pkgs.coreutils}/bin/tr -d '[:space:]' < ${lib.escapeShellArg entry.tokenFile}
    '';

  text = lib.concatStrings (
    lib.mapAttrsToList (
      name: entry: "${key entry.registry}:tokenHelper=${tokenHelper name entry}\n"
    ) cfg
  );
in
{
  options.nstdl.programs.pnpm.registryAuth = lib.mkOption {
    default = { };
    description = ''
      Private npm registry credentials for pnpm.

      Each entry names a file decrypted on this machine, typically by agenix.
      `auth.ini` holds only a `tokenHelper` that reads the file whenever pnpm
      needs the token, so the token is never evaluated into a derivation or
      copied elsewhere.

      nstdl owns the whole file, so declare every authenticated registry
      here.
    '';
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          registry = lib.mkOption {
            type = lib.types.str;
            example = "https://forge.example.com/api/packages/me/npm/";
            description = "Registry URL. The scheme is stripped to form the auth key.";
          };

          tokenFile = lib.mkOption {
            type = lib.types.str;
            description = ''
              Absolute path to a file containing only the token, typically
              `osConfig.age.secrets.<name>.path`. It must be readable by this
              user: set the agenix secret's `owner`, which defaults to root.
              A string, not a Nix path: a path literal would copy the secret
              into the world-readable store.
            '';
          };
        };
      }
    );
  };

  config = lib.mkIf (cfg != { }) {
    xdg.configFile."pnpm/auth.ini" = lib.mkIf useXdg {
      inherit text;
      force = true;
    };
    # Always on Darwin: it replaces a token copy written there before
    # tokenHelper, even once pnpm reads the XDG file instead.
    home.file."Library/Preferences/pnpm/auth.ini" = lib.mkIf pkgs.stdenv.isDarwin {
      inherit text;
      force = true;
    };
  };
}
