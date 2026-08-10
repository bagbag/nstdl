{
  description = "nstdl flake-module evaluation fixture";

  inputs = {
    nstdl.url = "path:../..";

    flake-parts.follows = "nstdl/flake-parts";
    nixpkgs.follows = "nstdl/nixpkgs";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.nstdl.flakeModules.default ];

      # A consumer may keep a direct configuration beside nstdl-managed hosts.
      flake.nixosConfigurations.test-direct = inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          {
            networking.hostName = "test-direct";
            boot.loader.grub = {
              enable = true;
              devices = [ "nodev" ];
            };
            fileSystems."/" = {
              device = "/dev/null";
              fsType = "ext4";
            };
            system.stateVersion = "25.11";
          }
        ];
      };

      nstdl = {
        accounts.people.tester.sshKeys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMM/o1cLFjnD1m41DE41yWySYzOjvN7MizVJLIpbhbXN tester"
        ];
        accounts.people.alice.sshKeys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPpPhXfy+OmQXWkjhFxn68tDs+++MTXzpSgMS3iM5gwN alice"
        ];
        secrets = {
          administrators.fixture.keys = {
            primary = {
              identity = "/tmp/test-master-age-key";
              publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMM/o1cLFjnD1m41DE41yWySYzOjvN7MizVJLIpbhbXN";
            };
            secondary = {
              identity = "/tmp/test-master-age-key";
              publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICvnCyc7hK0Tb5bXujzcjF+FjpmGi4FnfD9y84RtU6ZQ fixture-secondary";
            };
          };
          recoveryRecipients = [ "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq" ];
          items.database-password = {
            rekeyFile = ./server-admin-password-hash;
            access.test-secrets.users = [ "postgres" ];
          };
          items.db-prod = {
            rekeyFile = ./server-admin-password-hash;
            access.test-secrets.users = [ "nobody" ];
          };
          items."db.prod" = {
            rekeyFile = ./server-admin-password-hash;
            access.test-secrets.users = [ "postgres" ];
          };
          storage.root = ./. + "/secrets/rekeyed";
        };

        hosts = {
          test-server = {
            platform = "nixos";
            system = "x86_64-linux";
            role = "server";
            virtualization = "qemu";
            systemStateVersion = "25.11";
            deployment = {
              enable = true;
              targetHost = "test-server.example";
            };
            network = {
              interface = "ens3";
              addresses = [ "192.0.2.10/24" ];
              gateways = [ "192.0.2.1" ];
              dns = [ "192.0.2.53" ];
            };
            accounts = {
              extraSshUsers = [ "deploy" ];
              root = {
                enable = true;
                sshPeople = [ "alice" ];
              };
              users.admin = {
                people = [ "alice" ];
              };
            };
            extraModules = [
              {
                fileSystems."/" = {
                  device = "/dev/null";
                  fsType = "ext4";
                };
              }
            ];
          };

          test-workstation = {
            platform = "nixos";
            system = "x86_64-linux";
            role = "workstation";
            virtualization = "vmware";
            features = [
              "developer"
              "desktop-apps"
              "podman"
              "remote-access"
              "full-stack-developer"
              "intel"
              "laptop"
            ];
            systemStateVersion = "25.11";
            accounts = {
              primary = "tester";
              users.tester = {
                administrator = true;
                home = {
                  enable = true;
                  stateVersion = "25.11";
                  features = [
                    "workstation"
                    "developer"
                    "developer-extras"
                    "desktop-apps"
                    "full-stack-developer"
                    "gnome-extras"
                    "messaging"
                    "ai-agent-tools"
                  ];
                };
              };
              users.alice.home = {
                enable = true;
                stateVersion = "25.11";
                features = [ "developer" ];
              };
            };
            extraModules = [
              {
                fileSystems."/" = {
                  device = "/dev/null";
                  fsType = "ext4";
                };
              }
            ];
          };

          test-root-only = {
            platform = "nixos";
            system = "x86_64-linux";
            role = "server";
            systemStateVersion = "25.11";
            accounts.root = {
              enable = true;
              sshPeople = [ "tester" ];
            };
            extraModules = [
              {
                fileSystems."/" = {
                  device = "/dev/null";
                  fsType = "ext4";
                };
              }
            ];
          };

          test-postgresql = {
            platform = "nixos";
            system = "x86_64-linux";
            role = "server";
            features = [ "postgresql" ];
            systemStateVersion = "25.11";
            extraModules = [
              {
                fileSystems."/" = {
                  device = "/dev/null";
                  fsType = "ext4";
                };

                services.nstdl.postgresql = {
                  enable = true;
                  roles.app = {
                    enable = true;
                    connectionLimit = 20;
                    memberOf = [ "app_readers" ];
                    passwordFile = "/run/agenix/app-db-password";
                  };
                  roles.app_readers.enable = true;
                  databases.app = {
                    owner = "app";
                    extensions = [ "pgcrypto" ];
                  };
                };
                services.nstdl.postgresql.backup = {
                  enable = true;
                  location = "/var/backup/postgresql";
                  defaults = {
                    calendar = "hourly";
                    compression = "zstd";
                    retentionDays = 14;
                  };
                  jobs = {
                    app = { };
                    app_plain = {
                      database = "app";
                      format = "plain";
                      compression = "none";
                    };
                    globals = {
                      kind = "globals";
                      format = "plain";
                      compression = "gzip";
                      compressionLevel = 6;
                    };
                  };
                };
              }
            ];
          };

          test-secrets = {
            platform = "nixos";
            system = "x86_64-linux";
            role = "server";
            features = [ "secrets" ];
            secrets.hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPpPhXfy+OmQXWkjhFxn68tDs+++MTXzpSgMS3iM5gwN";
            systemStateVersion = "25.11";
            accounts.users.admin = {
              people = [ "alice" ];
              administrator = true;
            };
            extraModules = [
              ({ config, ... }: {
                nstdl.accounts.users.admin.hashedPasswordFile = config.age.secrets.database-password.path;
              })
              {
                fileSystems."/" = {
                  device = "/dev/null";
                  fsType = "ext4";
                };
              }
            ];
          };

          test-storage = {
            platform = "nixos";
            system = "x86_64-linux";
            role = "server";
            systemStateVersion = "25.11";
            storage = {
              device = "/dev/vda";
              encryption = "luks";
            };
          };

          test-storage-plain = {
            platform = "nixos";
            system = "x86_64-linux";
            role = "server";
            systemStateVersion = "25.11";
            storage = {
              device = "/dev/vdb";
              encryption = "none";
              snapshots.enable = false;
            };
          };

          test-proxmox-backup = {
            platform = "nixos";
            system = "x86_64-linux";
            role = "server";
            features = [ "proxmox-backup" ];
            systemStateVersion = "25.11";
            extraModules = [
              {
                fileSystems."/" = {
                  device = "/dev/null";
                  fsType = "ext4";
                };

                services.nstdl.proxmoxBackup = {
                  enable = true;
                  defaults = {
                    user = "root";
                    group = "root";
                    namespace = "default-namespace";
                    calendar = "hourly";
                    persistent = false;
                    changeDetectionMode = "metadata";
                    excludes = [ "/var/cache" ];
                    prune.keep = {
                      daily = 7;
                    };
                  };
                  jobs.system = {
                    repository = "backup@pbs!fixture@pbs.example:store";
                    passwordFile = "/run/agenix/pbs-token";
                    fingerprint = "aa:bb:cc:dd";
                    namespace = "servers";
                    calendar = "daily";
                    user = "nobody";
                    group = "nogroup";
                    archives = {
                      root = "/";
                      disk = {
                        type = "img";
                        source = "/dev/vda";
                      };
                    };
                    excludes = [ "/nix/store" ];
                    encryption = {
                      keyFile = "/run/agenix/pbs-key";
                      passwordFile = "/run/agenix/pbs-key-password";
                    };
                    prune.keep.weekly = 4;
                  };
                  jobs.defaulted = {
                    repository = "backup@pbs!fixture@pbs.example:store";
                    passwordFile = "/run/agenix/pbs-token";
                    fingerprint = "aa:bb:cc:dd";
                    archives.root = "/";
                  };
                };
              }
            ];
          };

          test-darwin = {
            platform = "darwin";
            system = "aarch64-darwin";
            role = "workstation";
            features = [
              "developer"
              "desktop-apps"
              "podman"
              "battery-charge-limit"
              "sleepless"
              "secrets"
              "messaging"
              "ai-agent-tools"
            ];
            secrets.hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHBJaMs/1fLo7FOQD5xTHc7Pox4rHN5G6hX96P81DO4e";
            systemStateVersion = 6;
            accounts = {
              primary = "tester";
              users.tester.home = {
                enable = true;
                stateVersion = "25.11";
                features = [
                  "workstation"
                  "developer"
                  "desktop-apps"
                  "ai-agent-tools"
                ];
              };
            };
          };
        };

        homes.test-standalone = {
          system = "x86_64-linux";
          userName = "tester";
          homeDirectory = "/home/tester";
          stateVersion = "25.11";
          features = [ "developer" ];
        };
      };
    };
}
