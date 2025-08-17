# nstdl - Nix Standard Infrastructure Library

`nstdl` is an opinionated, shared baseline for NixOS systems. It is not a standalone configuration, but a **library flake** intended to be imported into your own system flakes. It provides a robust set of modules and abstractions to accelerate the setup and management of production-ready NixOS infrastructure.

## Core Philosophy

- **Declarative Abstractions:** Provides high-level, declarative options for complex tasks like disk partitioning (`disko`), secret management (`ragenix`/`age`), user management, and database administration. This reduces boilerplate and enforces consistency.
- **Opinionated Defaults:** Implements sane defaults for security, maintenance, and system configuration, allowing you to get a well-configured system up and running quickly.
- **Production-Ready:** Includes modules for common infrastructure needs, such as managed databases (PostgreSQL, MariaDB) and robust, scheduled backups (PostgreSQL, Proxmox Backup Server).
- **Modular & Composable:** Built with flakes and Snowfall Lib, it's designed to be a clean, composable layer in your existing NixOS configurations.

---

## Quick Start

`nstdl` provides a `mkFlake` helper function to minimize boilerplate in your flake. It wraps `snowfall-lib` and automatically injects base modules and host-specific configurations.

1.  **Set up your `flake.nix`:**

    Use `inputs.nstdl.mkFlake` instead of `snowfall-lib.mkFlake`. Define your machine configurations in a central `hosts` attribute set. `nstdl` will automatically inject this data into each corresponding host's configuration.

    ```nix
    # flake.nix
    {
      description = "A demo flake using nstdl";

      inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05"; # Or nixos-unstable

        # Add nstdl as an input
        nstdl = {
          url = "github:bagbag/nstdl";
          inputs.nixpkgs.follows = "nixpkgs";
        };
      };

      outputs = { self, ... }@inputs:
        let
          # Define host-specific data centrally. The mkFlake helper injects this
          # into each host's configuration as `config.nstdl.hostConfig`.
          # The host key ("demo-server") must match a host directory name.
          hosts = {
            "demo-server" = {
              domain = "example.com";
              interface = "eth0";
              ipv4 = "10.0.0.10/24";
              gateway4 = "10.0.0.1";
              # You can also add ipv6, etc.
            };
          };
        in

        # Use the nstdl mkFlake helper to reduce boilerplate.
        # It wraps snowfall-lib, automatically adding base modules and host data.
        inputs.nstdl.mkFlake {
          inherit self inputs hosts;
          src = ./.; # The root of your flake, which snowfall-lib scans.
        };
    }
    ```

2.  **Create your host configuration:**

    In your host file (e.g., `systems/x86_64-linux/demo-server/default.nix`), you can now directly use the `nstdl` modules. Note that you no longer need to manually import the base modules or define `nstdl.hostConfig`, as `mkFlake` handles this.

    ```nix
    # systems/x86_64-linux/demo-server/default.nix
    { pkgs, ... }:
    {
      system.stateVersion = "25.05";

      # Use nstdl's declarative disk management
      nstdl.disko = {
        enable = true;
        disks.os = {
          device = "/dev/vda"; # or /dev/disk/by-id/...
          content = [ "boot" "root" "nix" "swap" ];
        };
      };

      # Use nstdl's declarative user management
      nstdl.interactiveUsers = {
        enable = true;
        defaultSshKeys = [
          "ssh-ed25519 AAAA..." # Your main public key that is added to all users
        ];
        users = {
          alice = {
            isAdmin = true; # Grants passwordless sudo/doas
            extraSshKeys = [
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... alice@example.com"
            ];
          };
        };
      };

      # Example of using a managed service
      services.nstdl.postgresql-backup = {
        enable = true;
        backupAll.enable = true;
        calendar = "daily";
        retentionDays = 14;
      };

      # Your other system configuration...
      services.nginx.enable = true;
      networking.firewall.allowedTCPPorts = [ 80 ];
    }
    ```

---

## Features

`nstdl` provides a wide range of modules under the `nstdl` and `services.nstdl` option namespaces.

### System Configuration

- **Base Configuration (`nstdl.hostConfig`)**: A central place to define host-specific settings like hostname, domain, network interfaces, and IP addresses.
- **User Management (`nstdl.interactiveUsers`)**: Declaratively create system users, grant admin privileges (`doas`/`sudo`), and assign SSH keys. Integrates with Home Manager.
- **Disk Management (`nstdl.disko`)**: An abstraction over `disko` for defining disk layouts, including encrypted BTRFS setups with subvolumes.
- **Secret Management (`nstdl.age`)**: A wrapper around `age` that adds host-based Access Control Lists (ACLs), allowing you to specify which users on which hosts can access a given secret.
- **Sane Defaults**: Automatic garbage collection, hardened security settings, kernel parameters, and more.

### Managed Services

- **PostgreSQL Backups (`services.nstdl.postgresql-backup`)**: Highly configurable, scheduled backups for PostgreSQL using `pg_dump` or `pg_dumpall`. Features compression, retention policies, and `systemd` timer integration.
- **Proxmox Backups (`services.nstdl.proxmox-backup`)**: Declaratively configure `proxmox-backup-client` jobs for file or block-level backups to a Proxmox Backup Server, including pruning, encryption, and GC jobs.
- **Managed Databases**:
  - `services.nstdl.postgresql-managed`: Declaratively manage PostgreSQL users, databases, owners, and privileges.
  - `services.nstdl.mariadb-managed`: Declaratively manage MariaDB users, databases, and privileges.
- **Home Manager**: Provides a common set of Home Manager configurations for users, including a pre-configured Zsh shell with modern tools like `eza`, `bat`, `fzf`, and useful aliases.

---

## Module Examples

### Declarative Disks with `nstdl.disko`

Define a fully encrypted BTRFS system disk with standard subvolumes.

```nix
{
  nstdl.disko = {
    enable = true;
    disks = {
      os = {
        device = "/dev/disk/by-id/nvme-eui.0123456789abcdef";
        encrypted = true;
        content = [ "boot" "root" "home" "nix" "swap" ];
        swapSize = "8G";
      };
    };
  };
}
```

### Secure Secrets with `nstdl.age`

Define secrets and control access on a per-host, per-user basis. Based on ragenix.

```nix
{
  nstdl.age = {
    secretsBaseDir = ./secrets; # Automatically finds secrets/my-app-key.age

    secrets = {
      "my-app-key" = {
        # Grant user `jane` on `server1` read access.
        # This will create a group `secret-my-app-key` and set permissions.
        acl."server1" = [ "jane" ];

        # Grant user `deploy` on `server2` read access.
        acl."server2" = [ "deploy" ];
      };
    };
  };
}
```

### Proxmox Backups

Configure a daily backup of the root filesystem and a weekly garbage collection job.

```nix
{
  services.nstdl.proxmox-backup = {
    defaults = {
      repository = "deploy@pbs.example.com:my-datastore";
      passwordFile = config.age.secrets."pbs-password".path;
      fingerprint = "0c:ac:d8:52:67:3a:4a:d5:67:96:2a:83:8e:f1:ac:73...";
    };

    jobs.system-backup = {
      paths = [ "root.pxar:/" ];
      namespace = "servers";
      backupId = config.nstdl.hostConfig.hostname;
      exclude = [ "/var/cache" "/tmp" ];
      calendar = "daily";
      prune = {
        enable = true;
        keep = {
          daily = 7;
          weekly = 4;
          monthly = 3;
        };
      };
    };

    gcJobs.weekly-gc = {
      calendar = "weekly";
    };
  };
}
```
