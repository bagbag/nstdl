{ lib, pkgs, ... }:
{
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = lib.mkDefault false;
      KbdInteractiveAuthentication = lib.mkDefault true;
      PermitRootLogin = lib.mkDefault "prohibit-password";
    };
  };

  networking = {
    nftables.enable = true;

    firewall = {
      enable = true;
      allowPing = true;
    };
  };

  security.doas = {
    enable = true;
    extraRules = [
      {
        groups = [ "wheel" ];
        noPass = true;
      }
    ];
  };

  # Enable sudo for modules not working with doas
  security.sudo = {
    enable = true;
    extraRules = [
      {
        groups = [ "wheel" ];
        commands = [
          {
            command = "ALL";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };

  boot.kernel.sysctl = {
    # Mitigate SYN flood attacks
    "net.ipv4.tcp_syncookies" = 1;
    # Protect against IP spoofing
    "net.ipv4.conf.default.rp_filter" = 1;
    "net.ipv4.conf.all.rp_filter" = 1;
    # Hide kernel pointers
    "kernel.kptr_restrict" = 1;
    # Disable unprivileged user namespaces
    "kernel.unprivileged_userns_clone" = 0;
    # Improve ASLR
    "kernel.randomize_va_space" = 2;
  };
}
