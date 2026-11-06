# The host's `nstdl`: operator commands that modules (or the consumer) register
# under `nstdl.commands.<area>.<action>`. Repository commands stay with the
# controller's `./nstdl`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nstdl.commands;
  validName = name: builtins.match "[a-z][a-z0-9-]*" name != null;
  names = lib.concatLists (
    lib.mapAttrsToList (area: actions: [ area ] ++ lib.attrNames actions) cfg
  );
  commandType = lib.types.submodule {
    options = {
      program = lib.mkOption {
        type = lib.types.path;
        description = "Executable run with the remaining arguments.";
      };
      description = lib.mkOption {
        type = lib.types.singleLineStr;
        description = "One-line summary shown in the command list, arguments first.";
      };
    };
  };
  dispatcher = pkgs.callPackage ../../packages/nstdl-host {
    commands = pkgs.writeText "nstdl-commands.json" (
      builtins.toJSON {
        host = config.networking.hostName;
        # Interpolated, so a path program is copied to the store and every
        # program stays in the dispatcher's closure.
        commands = lib.mapAttrs (
          _: lib.mapAttrs (
            _: command: {
              program = "${command.program}";
              inherit (command) description;
            }
          )
        ) cfg;
      }
    );
  };
in
{
  options.nstdl.commands = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf commandType);
    default = { };
    example = lib.literalExpression ''
      {
        app.reindex = {
          program = pkgs.writeShellScript "reindex" "...";
          description = "rebuild the search index";
        };
      }
    '';
    description = "Operator commands run as `nstdl <area> <action>` on this host.";
  };

  config = {
    assertions = [
      {
        assertion = lib.all validName names;
        message = "nstdl.commands areas and actions must match [a-z][a-z0-9-]*.";
      }
    ];
    environment.systemPackages = [ dispatcher ];
  };
}
