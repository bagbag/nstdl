# nstdl - Nix Standard Infrastructure Library

`nstdl` is an opinionated, shared baseline for NixOS systems. It is not a standalone configuration, but a **library flake** intended to be imported into your own system flakes. It provides a robust set of modules and abstractions to accelerate the setup and management of production-ready NixOS infrastructure.

## Core Philosophy

- **Declarative Abstractions:** Provides high-level, declarative options for complex tasks like disk partitioning (`disko`), networking, firewalling, secret management (`ragenix`/`age`), user management, and database administration. This reduces boilerplate and enforces consistency.
- **Opinionated Defaults:** Implements sane defaults for security, maintenance, and system configuration, allowing you to get a well-configured system up and running quickly.
- **Production-Ready:** Includes modules for common infrastructure needs, such as managed databases (PostgreSQL, MariaDB), robust, scheduled backups (PostgreSQL, Proxmox Backup Server), and seamless deployment tooling (`deploy-rs`).
- **Modular & Composable:** Built with flakes and Snowfall Lib, it's designed to be a clean, composable layer in your existing NixOS configurations.

---

## Quick Start

`nstdl` provides a `mkFlake` helper function to minimize boilerplate in your flake. It wraps `snowfall-lib` and automatically injects base modules and host-specific configurations.

1.  **Set up your `flake.nix`:**

    Use `inputs.nstdl.mkFlake` instead of `snowfall-lib.mkFlake`. Define your machine configurations in a central `hosts` attribute set. `nstdl` will automatically inject this data into each corresponding host's configuration and generate `deploy-rs` tasks.

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
        # It wraps snowfall-lib, automatically adding base modules, host data,
        # and deploy-rs integration.
        inputs.nstdl.mkFlake {
          inherit self inputs hosts;
          src = ./.; # The root of your flake, which snowfall-lib scans.
        };
    }
    ```

2.  **Create your host configuration:**

    In your host file (e.g., `systems/x86_64-linux/demo-server/default.nix`), you can now directly use the `nstdl` modules. The `mkFlake` helper handles importing base modules and injecting `nstdl.hostConfig`.

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
    }
    ```

3.  **Deploy your system:**

    The `mkFlake` helper automatically generates a `deploy` output compatible with `deploy-rs`.

    ```sh
    # Deploy the demo-server configuration
    nix run github:serokell/deploy-rs -- .#demo-server
    ```

---

## Features

`nstdl` provides a wide range of modules under the `nstdl` and `services.nstdl` option namespaces.

### Core Abstraction: `mkFlake`

The `mkFlake` helper function is the heart of `nstdl`, designed to streamline your flake setup:

- **Wraps `snowfall-lib`**: Reduces boilerplate for system and user (Home Manager) configurations.
- **Injects `hostConfig`**: Automatically makes your central `hosts` data available in each machine's configuration.
- **Provides Base Modules**: Includes a common set of NixOS and Home Manager modules for a consistent baseline.
- **Auto-discovery**: Can dynamically load environment- or disko-specific configurations.
- **`deploy-rs` Integration**: Automatically generates `deploy-rs` configurations and checks for seamless deployments via a `deploy` flake output.

### System Configuration (`nstdl.*`)

- **Base System & Security**: Implements an opinionated set of defaults for a robust server, including `systemd-boot`, `zswap` for memory compression, automatic Nix garbage collection, and hardened security settings (`doas`, secure kernel `sysctl` parameters).
- **Host Configuration (`nstdl.hostConfig`)**: A central place to define host-specific settings like hostname, domain, network interfaces, and IP addresses.
- **Networking (`nstdl.networking`)**: Uses the data from `hostConfig` to declaratively configure `systemd-networkd`, simplifying static IP management.
- **Disk Management (`nstdl.disko`)**: A high-level abstraction over `disko` for declaratively defining disk layouts. Easily configure complex setups like encrypted BTRFS on LUKS with standard subvolumes (`root`, `home`, `nix`, `swap`).
- **User Management (`nstdl.interactiveUsers`)**: Declaratively create system users, grant admin privileges (`doas`/`sudo`), and assign SSH keys. Integrates with Home Manager for a seamless user environment.
- **Secret Management (`nstdl.age`)**: A powerful wrapper around `ragenix` that adds host-based Access Control Lists (ACLs). Define a secret once and declaratively manage which users on which specific hosts are granted read access.

### Managed Services (`services.nstdl.*`)

- **Declarative Databases**:
  - `services.nstdl.postgresql-managed`: Declaratively manage PostgreSQL users, databases, owners, and privileges.
  - `services.nstdl.mariadb-managed`: Declaratively manage MariaDB users, databases, and privileges.
- **Robust Backups**:
  - **PostgreSQL Backups (`services.nstdl.postgresql-backup`)**: Highly configurable, scheduled backups for PostgreSQL using `pg_dump` or `pg_dumpall`. Features compression (zstd, gzip), custom retention policies, and `systemd` timer integration.
  - **Proxmox Backups (`services.nstdl.proxmox-backup`)**: Declaratively configure `proxmox-backup-client` jobs for file or block-level backups to a Proxmox Backup Server. Includes scheduling, automated pruning, client-side encryption, and garbage collection jobs.

### User Environment (Home Manager)

- Provides a common set of Home Manager configurations for all managed users, including a pre-configured Zsh shell with modern tools like `eza`, `bat`, `fzf`, `ripgrep`, and useful aliases.

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

Define secrets and control access on a per-host, per-user basis. This module is based on `ragenix`.

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

### Managed PostgreSQL

Declaratively create a database and a user, granting it privileges and managing its password with `nstdl.age`.

```nix
{
  # Assumes the password is managed via nstdl.age
  services.nstdl.postgresql-managed = {
    enable = true;
    databases.my_app_db = {
      ensureExists = true;
      owner = "app-user";
    };
    users.app-user = {
      enable = true;
      passwordFile = config.age.secrets."postgres-app-user.password".path;
      privileges = [
        # Grant connect on the database itself
        { database = "my_app_db"; on = "DATABASE \"my_app_db\""; grant = "CONNECT"; }
        # Grant usage on the public schema
        { database = "my_app_db"; on = "SCHEMA \"public\""; grant = "USAGE"; }
        # Grant full rights on all tables in the public schema
        { database = "my_app_db"; on = "ALL TABLES IN SCHEMA \"public\""; grant = "ALL PRIVILEGES"; }
      ];
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
