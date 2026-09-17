{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nstdl.programs.pnpm.registryAuth;

  # pnpm 11 keeps credentials in auth.ini, separate from config.yaml, so
  # writing this does not conflict with a managed config.yaml or .npmrc.
  authFile =
    if pkgs.stdenv.isDarwin then "Library/Preferences/pnpm/auth.ini" else ".config/pnpm/auth.ini";

  line =
    entry: "//${lib.removePrefix "https://" (lib.removePrefix "http://" entry.registry)}:_authToken=";
in
{
  options.nstdl.programs.pnpm.registryAuth = lib.mkOption {
    default = { };
    description = ''
      Private npm registry credentials for pnpm, written to `auth.ini` at
      activation from files outside the Nix store.

      Each entry names a file decrypted on this machine, typically by agenix;
      the token itself is never evaluated into a derivation. `pnpm config set`
      is avoided because it takes the token as a command-line argument, which
      is visible in the process list.

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
              `osConfig.age.secrets.<name>.path`. A string, not a Nix path: a
              path literal would copy the secret into the world-readable store.
            '';
          };
        };
      }
    );
  };

  config = lib.mkIf (cfg != { }) {
    home.activation.nstdlPnpmRegistryAuth = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      authPath="$HOME/${authFile}"
      run mkdir -p "$(dirname "$authPath")"

      # Created at 0600 rather than tightened afterwards, so the token is
      # never briefly world-readable.
      tmp="$(mktemp)"
      chmod 0600 "$tmp"
      ok=1
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: entry: ''
          # agenix decrypts from its own launchd daemon on darwin, so the
          # source can lag behind home-manager activation.
          for _ in $(seq 1 30); do
            [ -r "${entry.tokenFile}" ] && break
            sleep 1
          done

          if [ -r "${entry.tokenFile}" ]; then
            printf '%s%s\n' ${lib.escapeShellArg (line entry)} "$(tr -d '[:space:]' < ${lib.escapeShellArg entry.tokenFile})" >> "$tmp"
          else
            echo "nstdl: pnpm registry auth '${name}': ${entry.tokenFile} is not readable" >&2
            ok=0
          fi
        '') cfg
      )}

      if [ "$ok" = 1 ]; then
        run install -m 0600 "$tmp" "$authPath"
      else
        echo "nstdl: leaving $authPath untouched because a token file was missing" >&2
      fi
      rm -f "$tmp"
    '';
  };
}
