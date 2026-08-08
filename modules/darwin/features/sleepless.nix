{ source }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  userName = config.nstdl.user.name;
  package = pkgs.callPackage ../../../packages/sleepless.nix { src = source; };
in
{
  assertions = [
    {
      assertion = userName == null || builtins.match "^[A-Za-z0-9._-]+$" userName != null;
      message = "nstdl Sleepless requires a sudoers-safe primary user name.";
    }
  ];

  environment.systemPackages = [ package ];

  security.sudo.extraConfig = lib.mkIf (userName != null) ''
    ${userName} ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
  '';
}
