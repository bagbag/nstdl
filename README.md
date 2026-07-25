# nstdl

`nstdl` is an opinionated Nix configuration library for personal devices and
servers. It provides small, role-based consumer configurations while keeping
hardware, identities, secrets, and site-specific networking local to each
consumer.

This is a breaking redesign. The former Snowfall and `mkFlake` APIs are gone.

## Use with flake-parts

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    nstdl = {
      url = "github:bagbag/nstdl";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.nstdl.flakeModules.default ];

      nstdl = {
        accounts.people.deploy.sshKeys = [
          "ssh-ed25519 AAAA... deploy@example.com"
        ];

        hosts.app-01 = {
          platform = "nixos";
          system = "x86_64-linux";
          role = "server";
          virtualization = "qemu";
          features = [ "developer" ];
          systemStateVersion = "26.05";
          accounts = {
            primary = "deploy";
            users.deploy.people = [ "deploy" ];
            root = {
              enable = true;
              sshPeople = [ "deploy" ];
            };
          };
          extraModules = [ ./hosts/app-01.nix ];
        };
      };
    };
}
```

`accounts.people` defines reusable public SSH keys; each host's
`accounts.users` selects the people allowed to access its Unix accounts. The
default is the matching name, as in `users.deploy` above. Server administrators
must also set a secret-backed `hashedPasswordFile`; ordinary deploy accounts do
not receive sudo by default. The example instead enables an explicit
SSH-key-only root break-glass path. Production servers should normally use a
dedicated administrator account with a runtime password hash and enable root
only when that recovery path is required.

`role` is exclusive: choose `server` or `workstation`. `features` are
additive. `developer` provides system tooling; add it to an account's
`home.features` when that person's Home Manager profile should receive the
opinionated terminal configuration. `virtualization` is the one portable host
selector: use `"none"` (the default), `"qemu"`, or `"vmware"` to enable the
corresponding NixOS guest agent. A host module remains the place for all other
host facts.

The resulting configuration is available as `.#nixosConfigurations.app-01`.
For example, build it with `nix build .#nixosConfigurations.app-01.config.system.build.toplevel`.

## Host facts and accounts

Put generated hardware configuration, filesystem mounts, site-specific
services, and exceptional networking in `extraModules`. Do not put any secret
contents in the flake:

```nix
nstdl.hosts.app-01.extraModules = [
  ./hosts/app-01/hardware-configuration.nix
  ({ ... }: {
    services.nginx.enable = true;
  })
];
```

For a workstation, opt each person into Home Manager explicitly. State versions
remain consumer-owned:

```nix
nstdl.hosts.laptop.accounts = {
  primary = "patrick";
  users.patrick = {
    people = [ "patrick" ];
    administrator = true;
    home = {
      enable = true;
      stateVersion = "26.05";
      features = [ "workstation" "developer" "desktop-apps" ];
    };
  };
};
```

## Storage, networking, and deployment

For a new, single-disk NixOS machine, the narrow standard layout creates EFI,
Btrfs subvolumes, hourly snapshots (72 hourly, 14 daily, four weekly), and a
monthly scrub. The explicit LUKS option uses an interactive boot passphrase;
headless unlock and multi-disk layouts belong in a reviewed `extraModules`
module.

```nix
nstdl.hosts.app-01 = {
  storage = {
    device = "/dev/disk/by-id/virtio-app-01";
    encryption = "luks"; # or "none"
  };
  network = {
    interface = "ens3";
    addresses = [ "192.0.2.10/24" ];
    gateways = [ "192.0.2.1" ];
    dns = [ "192.0.2.53" ];
  };
  deployment = {
    enable = true;
    targetHost = "app-01.example";
  };
};
```

`network`, `storage`, and `deployment` are NixOS-only. The latter emits a
`deploy-rs` system profile; complex network topologies remain host-local.

## Secrets

Select the `secrets` feature only on hosts that materialise runtime secrets.
Administrators encrypt and rekey secrets locally; servers receive only their
own public runtime recipient and cannot edit canonical secret files.

```nix
nstdl = {
  secrets = {
    administrators.patrick = {
      identity = "/home/patrick/.ssh/id_ed25519";
      publicKey = "ssh-ed25519 AAAA... patrick";
    };
    recoveryRecipients = [ "age1...offline-recovery..." ];
    storage = {
      mode = "local";
      root = ./. + "/secrets/rekeyed";
    };
    items.database-password = {
      rekeyFile = ./secrets/database-password.age;
      access.app-01 = {
        users = [ "postgres" ];
        owner = "postgres";
        mode = "0440";
      };
    };
  };

  hosts.app-01 = {
    features = [ "secrets" ];
    secrets.hostPubkey = "ssh-ed25519 AAAA... app-01";
  };
};
```

An ACL controls runtime materialisation only; it does not make a service or
server an encryption recipient. Use `nix run .#agenix-rekey -- edit` and
`nix run .#agenix-rekey -- rekey` from the consuming flake. Keep all private
keys out of Nix configuration.

NixOS uses systemd-boot with EFI-variable updates and zram by default. Servers
use Linux 6.12 LTS; workstations use the latest kernel. See
[accounts](docs/rebuild/accounts.md) for reusable SSH identities, normal
accounts, and optional root break-glass access.

## Profiles

- `core`: firewall, garbage collection, Lix, systemd-boot/EFI, zram, and
  portable baseline defaults.
- `server`: OpenSSH and the LTS kernel.
- `workstation`: latest kernel, GNOME, audio, Bluetooth, fonts, Flatpak, and
  desktop baseline.
- `developer`: Nushell, Zsh, Ghostty, modern command-line tools, and the
  nix-index database.
- `postgresql`: typed PostgreSQL roles, databases, memberships, extensions, and
  local dump backups. Role passwords use runtime files loaded as systemd
  credentials, so their contents cannot enter nstdl's Nix configuration.
- `proxmox-backup`: typed, credential-backed Proxmox Backup Client jobs and
  one-off client wrappers.
- `secrets`: ragenix plus agenix-rekey, with explicit host runtime ACLs.

The NixOS, nix-darwin, and Home Manager profile modules are also exported for
explicit composition by consumers that do not use flake-parts. They do not
require a consumer to pass `inputs` through `specialArgs`.

## Input sharing

`nstdl` owns and locks its Home Manager, nix-darwin, nix-index-database, Disko,
and deploy-rs inputs. A normal consumer only needs to share `nixpkgs` and
`flake-parts`, as shown above.

If a consumer also imports Home Manager or nix-darwin directly, declare that
input in the consumer and make `nstdl` follow it so the lock file does not hold
two revisions:

```nix
home-manager.url = "github:nix-community/home-manager";
nstdl.inputs.home-manager.follows = "home-manager";

nix-darwin.url = "github:nix-darwin/nix-darwin";
nstdl.inputs.nix-darwin.follows = "nix-darwin";

disko.url = "github:nix-community/disko";
nstdl.inputs.disko.follows = "disko";

deploy-rs.url = "github:serokell/deploy-rs";
nstdl.inputs.deploy-rs.follows = "deploy-rs";
```

## Development

Run the evaluation fixture suite from the repository root:

```sh
bash tests/evaluate.sh
```

It evaluates NixOS server/workstation, Darwin workstation, standalone Home
Manager, the public raw module outputs, the repository example, and invalid
configuration boundaries.
