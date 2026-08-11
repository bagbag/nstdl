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
must also set `hashedPasswordFile = config.age.secrets.<name>.path` in a host
module; ordinary deploy accounts do
not receive sudo by default. The example instead enables an explicit
SSH-key-only root break-glass path. Production servers should normally use a
dedicated administrator account with a runtime password hash and enable root
only when that recovery path is required.

`role` is exclusive: choose `server` or `workstation`. `features` are
additive. `developer` provides system tooling; add it to an account's
`home.features` when that person's Home Manager profile should receive the
opinionated terminal configuration. `virtualization` is the one portable host
selector: use `"none"` (the default), `"qemu"`, or `"vmware"` to enable the
corresponding NixOS guest agent. Redistributable device firmware is enabled on
physical hosts and omitted from QEMU and VMware guests. A host module remains
the place for all other host facts.

The resulting configuration is available as `.#nixosConfigurations.app-01`.
For example, build it with `nix build .#nixosConfigurations.app-01.config.system.build.toplevel`.
You can also declare direct consumer-owned `flake.nixosConfigurations` or
`flake.darwinConfigurations` entries alongside nstdl-managed hosts, provided
that each configuration name is unique.

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
    administrators.patrick.keys = {
      workstation = {
        identity = "~/.ssh/id_ed25519";
        publicKey = "ssh-ed25519 AAAA... patrick@workstation";
      };
      laptop = {
        identity = "~/.ssh/id_ed25519";
        publicKey = "ssh-ed25519 AAAA... patrick@laptop";
      };
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

- `core`: firewall, scheduled `nh clean` maintenance, Lix, systemd-boot/EFI,
  zram, physical-host firmware, and portable baseline defaults.
- `server`: OpenSSH and the LTS kernel.
- `workstation`: latest kernel, GNOME, audio, Bluetooth, fonts, Flatpak, and
  desktop baseline.
- `developer`: Nushell, Zsh, Ghostty, modern command-line tools, and the
  nix-index database.
- Optional capabilities keep role defaults small: `foreign-binaries`,
  `container-development`, language toolchains, database and office tools,
  desktop application bundles, `vscode`, `ai-agent-tools`, and `secret-admin`.
  `ai-agent-tools` installs Codex and Claude Code through Nix on Linux; on
  Darwin it installs the Codex, Claude Code, Claude, and ChatGPT Homebrew
  casks.
  `messaging` installs Signal through Nix on Linux and the Discord and Signal
  Homebrew casks on Darwin.
  `full-stack-developer` supplies JavaScript, Python, native, and database
  tooling. Supporting utilities and document authoring remain owned by
  `developer-extras` and `document-tools`; personal identities, secrets,
  editor settings, and SSH hosts stay in the consuming configuration.
- `podman`: rootless Podman with DNS-enabled default networking and Docker Hub
  plus Quay search registries on NixOS; on macOS it supplies `podman` and
  `podman-compose`, while the user initializes and starts the Podman VM once
  with `podman machine init` and `podman machine start`.
- `battery-charge-limit`: on newer Apple Silicon firmware, configures `batt`
  through Homebrew with a 65–70% charge band. It keeps upstream diagnostic
  logging and allows local users to temporarily suspend the limit with
  `batt disable --for=1d`; the next configuration activation restores the
  declared band. Disable macOS Optimized Battery Charging and any native
  charge limit first, so batt is the only charge controller.
- `remote-access`: OpenSSH with firewall integration, disabled password and
  keyboard-interactive authentication, and key-only root break-glass support.
- `sleepless`: on Darwin, builds the pinned Sleepless fork from source, installs
  its app bundle through nix-darwin, and grants the primary user only the two
  exact `pmset disablesleep` commands the app needs. Its interactive grant and
  uninstall scripts are not included in the installed bundle.
- `intel`: Intel microcode, iHD VA-API, compute/NPU support, and active
  Intel P-state; `laptop` adds auto-cpufreq and thermald.
- `postgresql`: typed PostgreSQL roles, databases, memberships, extensions, and
  local dump backups. Role passwords use runtime files loaded as systemd
  credentials, so their contents cannot enter nstdl's Nix configuration.
- `proxmox-backup`: typed, credential-backed Proxmox Backup Client jobs and
  one-off client wrappers.
- `secrets`: ragenix plus agenix-rekey, with explicit host runtime ACLs.

NixOS hosts use an explicit locale policy. Its defaults are English messages,
German regional formatting, and the German `nodeadkeys` keyboard layout across
the console, display manager, and GNOME session. Override `hosts.<name>.locale`
when a host needs different language, formatting, or keyboard conventions.

nstdl is consumed through its flake-parts module. Direct NixOS, nix-darwin, and
Home Manager module composition is intentionally not a supported API.

## Input sharing

`nstdl` owns and locks its Home Manager, nix-darwin, nix-index-database, Disko,
and deploy-rs inputs. Its defaults pair unstable nixpkgs with Home Manager
master. A consumer using those defaults only needs to share `nixpkgs` and
`flake-parts`, as shown above.

A stable consumer must provide a matching nixpkgs and Home Manager release and
make nstdl follow both. For example, a 26.05 consumer uses:

```nix
nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

home-manager = {
  url = "github:nix-community/home-manager/release-26.05";
  inputs.nixpkgs.follows = "nixpkgs";
};

nstdl = {
  url = "github:bagbag/nstdl";
  inputs.nixpkgs.follows = "nixpkgs";
  inputs.home-manager.follows = "home-manager";
  inputs.flake-parts.follows = "flake-parts";
};
```

The developer profile supports both Home Manager channels. Features absent
from a stable Home Manager release, such as native fzf integration for
Nushell, are omitted while fzf, nstdl's explicit Nushell keybindings, and Atuin
remain available.

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
Manager, the repository example, invalid configuration boundaries, and the
supported unstable/master and 26.05/release-26.05 input pairs.
