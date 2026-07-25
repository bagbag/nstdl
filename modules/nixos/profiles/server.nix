{ lib, pkgs, ... }:
{
  # Linux 6.12 is the current long-term-support kernel in nstdl's nixpkgs revision.
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_6_12;

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = lib.mkDefault false;
      KbdInteractiveAuthentication = lib.mkDefault false;
      PermitRootLogin = lib.mkDefault "prohibit-password";
    };
  };

}
