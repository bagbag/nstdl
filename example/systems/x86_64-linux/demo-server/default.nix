{ inputs, pkgs, ... }:
{
  # It's good practice to set the state version.
  system.stateVersion = "25.05";

  # 3. Use nstdl's declarative disk management.
  # This defines a simple, unencrypted disk layout for a virtual machine.
  nstdl.disko = {
    enable = true;
    disks = {
      os = {
        device = "/dev/sda";
        content = [
          "boot" # Creates an EFI boot partition
          "root" # Creates a btrfs root subvolume mounted at /
          "nix" # Creates a btrfs nix subvolume mounted at /nix
          "swap" # Creates a swap partition
        ];
      };

      data = {
        device = "/dev/sdb";
        content = [
          "var" # Creates a btrfs var subvolume mounted at /var
          "data" # Creates a btrfs data subvolume mounted at /data
        ];
      };
    };
  };

  # 4. Use nstdl's declarative user management.
  nstdl.interactiveUsers = {
    enable = true;
    users.alice = {
      isAdmin = true; # Grants passwordless sudo/doas access
      homeStateVersion = "25.05"; # Enable Home Manager for this user
      extraSshKeys = [
        # Replace with your actual public SSH key
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAGtV/8gK8w+z0kZ4bL5G6f8g8j8Q8j8Q8j8Q8j8 alice@example"
      ];
    };
  };

  # 5. Add any other standard NixOS configuration.
  networking.firewall.allowedTCPPorts = [
    80
  ];

  services.nginx = {
    enable = true;

    virtualHosts."demo-server" = {
      root = pkgs.writeText "index.html" ''
        <h1>Hello from nstdl and Snowfall Lib!</h1>
      '';
    };
  };
}
