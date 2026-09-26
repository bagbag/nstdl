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
opinionated terminal configuration. On Darwin, `linux-builder` enables the
local Virtualization.framework builder for `aarch64-linux` and `x86_64-linux`
(see Profiles). `virtualization` is
the one portable host selector: use `"none"` (the default), `"qemu"`, or
`"vmware"` to enable the corresponding NixOS guest agent. Redistributable
device firmware is enabled on physical hosts and omitted from QEMU and VMware
guests. A host module remains
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

Deploy through the same wrapper the secrets use:

```console
./nstdl deploy app-01                     # build, show the diff, ask, activate
./nstdl diff                              # preview the current NixOS or Darwin machine
./nstdl diff --local app-01                # select a local host explicitly
./nstdl diff app-01                       # preview a deployable NixOS host over SSH
./nstdl diff --remote-build app-01        # build on the host, then preview
./nstdl deploy --no-rollback app-01       # keep the generation even if activation fails
./nstdl deploy --diff-files app-01        # also show generated file contents
./nstdl deploy app-01 --remote-build      # build on the host before activation
./nstdl deploy app-01 --boot              # update next boot, no activation now
./nstdl deploy app-01 --test              # activate without updating boot loader
```

With no host argument, `diff` matches the running machine's short hostname to
`nstdl.hosts.*.hostName` and builds its declared NixOS or Darwin system locally.
Use `--local HOST` when the machine name differs; `diff HOST` retains the remote
SSH preview for a deployable NixOS host. `--remote-build` applies only to that
remote preview. A local preview never activates the candidate.

`diff HOST` and `deploy HOST` share the same remote preview. Before activating,
`deploy` builds the system with `nom` output (on the host under
`--remote-build`), copies it and shows, against the host's running system: the
package diff (`nix store diff-closures`), the store paths rebuilt under an
existing name (configuration files and units included), declared executable names
added to or removed from the system and Home Manager paths, Home Manager package
and managed file changes for activated users, and the units the
switch would stop, start, restart or reload (`switch-to-configuration
dry-activate` under `sudo`, which may ask for the password), plus the units
`multi-user.target` wants that are not running: the switch restarts that
target, which starts them again — a service stopped by hand included. Then it asks;
`--yes` skips the question. `--no-rollback` disables both deploy-rs rollbacks: meant for a failure a
reboot clears, it also keeps a generation that locks you out. nstdl options go
before the host. The preview is advisory: deploy-rs evaluates again after approval,
so a concurrent flake change can change the deployed closure. Useful deploy-rs
activation modes such as `--boot`, `--test`, and `--dry-activate` are passed
through; nstdl labels the selected mode, and `--boot` skips the unit activation
preview. Target, profile, SSH, and extra build overrides are refused because
they would make the approved preview describe a different operation. Use
deploy-rs directly when those overrides are needed. Local NixOS previews include
the same unit dry activation. Darwin previews report Launchd file changes but
cannot predict every nix-darwin activation action. `--diff-files` prints `/etc`
and Home Manager file contents; on Darwin it also shows Launchd, activation
script, and Homebrew Brewfile contents.

It runs the deploy-rs this flake locks, matching the `activate-rs` in the
profile. A host whose secrets are missing or not rekeyed fails at evaluation.

## Consumer layout

Keep shared login keys in `accounts.nix`, the secret inventory in
`secrets/default.nix`, and each complete host declaration in
`hosts/HOST/default.nix`. Put `secrets.hostPubkey` in that host declaration.
Import these modules explicitly from the consumer's `flake.nix`:

```nix
imports = [
  inputs.nstdl.flakeModules.default
  ./accounts.nix
  ./secrets/default.nix
  ./hosts/app-01/default.nix
];
```

nstdl does not scan directories for modules. Add each new host import and
include the files in the Git flake source. Keep canonical and rekeyed `.age`
files under `secrets/`; ignore `/.installer-host-keys/` at the repository root.
That local directory holds the installer-side private host key and its `.pub`
sibling until installation is verified or the operator removes them.

## Installation

`nstdl install` installs an already declared NixOS configuration using its
Disko layout. Prepare and review hardware, networking, runtime secret recipient
and ciphertext before invoking it. For a fresh installed Ed25519 SSH host key,
run this from the consumer flake root:

```console
./nstdl prepare-host-key app-01
```

The command creates `.installer-host-keys/app-01/ssh_host_ed25519_key` and its
`.pub` sibling in a Git-ignored directory. It refuses an existing directory
and prints the fingerprint and a `secrets.hostPubkey` assignment to paste into
`hosts/app-01/default.nix`. If needed, it creates
`.installer-host-keys/.gitignore`; include that ignore file in Git, but never
include the key directory. The preparation package is separate from the
secret-dependent nstdl CLI, so it can run before the new host recipient is
declared. Include the host declaration in the consumer Git flake before using
it. Once all canonical secret values exist, run `./nstdl secret rekey`, then
`./nstdl secret status --check`. Use `secret set` or `secret sync` first if
values are missing. Rekeying updates encrypted host files and may stage them
in Git. Keep the private key available for retries; a reinstall retaining the
declared recipient needs the same key, recovered from the host or a backup if
the local copy has been removed. Losing it before installation requires an
explicit new identity, declaration update and rekey before retrying.

Run either remote form from a controller; use `nixos-installer` when the target
already booted a NixOS ISO:

```console
./nstdl install remote --bootstrap kexec --target root@rescue \
  --verify-target admin@installed app-01
./nstdl install remote --bootstrap nixos-installer --target root@installer \
  --verify-target admin@installed app-01
./nstdl install local app-01
```

Run `local` as root on the NixOS ISO console with the consumer flake and key
available there. It needs a Linux build or cached closures and evaluation
inputs; a standard ISO is not automatically prepared for offline use. All forms
default to `.installer-host-keys/HOST/ssh_host_ed25519_key`; use `--host-key PATH`
when recovering an existing identity from elsewhere. They require a terminal,
build the exact Disko script and system before formatting,
print the selected disks, and require a typed confirmation. The kexec form also
confirms the OS transition and rechecks the disks in the installer. Remote
installation uses nixos-anywhere to transfer the built outputs, format, install
and reboot. It then checks the installed SSH host key, running closure,
declared mount presence, concrete filesystem types and age secret metadata.
Local installation runs the same Disko script and exact system through pinned
`nixos-install`; its success means installation completed on disk, **not** that
the new system booted.
Neither result establishes application readiness.

Without `--kexec-image`, pinned nixos-anywhere downloads its default image,
normally on the target. That image is selected by a versioned upstream URL but
its contents are not pinned by this flake; the target normally needs internet
access. Supply `--kexec-image /nix/store/HASH-kexec.tar.gz` for a pre-acquired
image. Either image must preserve a way for the operator to connect over SSH
after the transition; nstdl checks that connection before formatting.
If an install fails after formatting starts, inspect the target and its mounted
root before retrying. A failed postboot check does not call for another format.

Pinned nixos-anywhere disables SSH host-key checking for its installer and Nix
transfer connections. A wrong endpoint or active intermediary can receive the
private installed host key and installation data, or have a disk formatted. The
postboot SSH key check cannot retroactively authenticate those connections.
`--yes` is unavailable for installation. The install command does not create
hardware configuration, generate identities, rekey secrets, or restore data.
It supports `disko.rootMountPoint = "/mnt"`; other mount roots are refused
before formatting.

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
      generator = { type = "random"; bytes = 32; };
      access.app-01 = {
        users = [ "postgres" ];
        owner = "postgres";
        mode = "0440";
      };
    };
    # Admin-only passphrase; only the hash derived from it reaches the host.
    items.console-password = {
      rekeyFile = ./secrets/console-password.age;
      generator.type = "passphrase";
    };
    items.console-password-hash = {
      rekeyFile = ./secrets/console-password-hash.age;
      generator = { type = "password-hash"; from = "console-password"; };
      access.app-01.mode = "0400";
    };
  };

  hosts.app-01 = {
    features = [ "secrets" ];
    secrets.hostPubkey = "ssh-ed25519 AAAA... app-01";
  };
};
```

An ACL controls runtime materialisation only; it does not make a service or
server an encryption recipient. Keep all private keys out of Nix configuration.

Secrets are managed with `nstdl secret`, run from the consuming flake's root.
Commit this wrapper there as an executable `nstdl`:

```sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ ${1-} == prepare-host-key ]]; then
  shift
  exec nix run .#prepare-host-key -- "$@"
fi
exec nix run .#nstdl -- "$@"
```

Never switch it to a `path:` reference: that copies ignored files into the
world-readable store.

- `./nstdl secret status [--check]` lists every declared secret, missing values
  and pending rekeys, and verifies derived hashes against their source when an
  administrator identity is available. An unavailable identity reports the pair
  as unverifiable rather than healthy; `--check` exits 3 on drift and is the only
  command CI may run.
- `./nstdl secret sync` creates missing generated values, repairs a derived hash
  that no longer matches its source, then rekeys. Run
  it after any change to the declarations, including a newly granted host.
- `./nstdl secret set ITEM` stores the first value of an externally issued
  secret (prompted, or from stdin) or, for a `password-hash` without `from`,
  hashes a self-chosen password. A hash derived from an entered value is
  created by setting that value. `set --replace ITEM` corrects an entered
  value after you type its name, regardless of `rotate`.
- `./nstdl secret rotate ITEM` replaces a value: it generates a new one, or
  asks for it (prompt or stdin) when the value is entered. It asks you to type
  the name first, unless `--yes` is given, and re-derives the hashes computed
  from it.
- `./nstdl secret edit ITEM` changes an externally issued value in `$EDITOR`.
  The value is written verbatim to a private file for the editor, which is
  memory-backed on Linux and in `$TMPDIR` on macOS, and removed afterwards.
  vim and nvim (also when reached as `vi`) run with `-n -i NONE` and without
  backup or undo files, micro without backups; none appends a final newline.
  With other editors, check their backup and history settings. An unchanged
  value writes nothing.
- `./nstdl secret view ITEM` and `verify ITEM` show a value or check a typed
  password against a stored hash. `rekey` rekeys without other changes.

Generators are `random` (`format` hex, base64 or base64url sized by `bytes`,
the count the value decodes to, default 32; or alphanumeric or
alphanumeric-lowercase sized by `length` in characters, at least 80 bits,
default 20),
`passphrase`
(`words` from the EFF long list, space-separated) and `password-hash` (yescrypt,
from another secret or prompted). A value is created once and never replaced
unless its item sets `rotate = true` (`rotate`, `edit`) or it is an entered
value corrected with `set --replace`; keep `rotate` false for keys whose change
breaks existing data. Derived hashes follow their source whenever it changes.
New files are added to git, and every changing command ends with a rekey —
deferred, naming what is missing, while a host-granted secret has no value,
because agenix-rekey refuses to run until all exist. Use `nstdl secret`
rather than agenix-rekey's own commands: its `generate` can replace existing
secrets.

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
  Darwin it installs the Codex, latest-channel Claude Code, Claude, and ChatGPT
  Homebrew casks.
  `messaging` installs Signal through Nix on Linux and the Discord and Signal
  Homebrew casks on Darwin.
  `qui` runs the qBittorrent web UI with systemd on NixOS and launchd on
  Darwin.
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
- `postgresql`: typed PostgreSQL roles, databases, memberships, extensions
  (created with `CASCADE`), and local dump backups. Role passwords use runtime
  files loaded as systemd credentials, so their contents cannot enter nstdl's
  Nix configuration. `vectorchord` adds the VectorChord index extension.
- `paradedb`: ParadeDB `pg_search`, at the version tstdl's development image
  runs rather than nixpkgs', built with a fenix toolchain and preloaded.
  Create it per database through `postgresql`'s `extensions`.
- `systemd-sandbox`: `services.nstdl.systemd.services.<name>.sandbox` applies a
  deny-by-default hardening preset to an existing unit; `relax` drops
  directives and `extend` appends to list-valued ones (`~` entries in
  `SystemCallFilter` deny). The unit's own settings win.
- `linux-builder` (Darwin): the Virtualization.framework builder, sized by
  `nstdl.linuxBuilder.{cores,memorySize,diskSize}`. `sandboxSecrets` delivers
  host secrets, such as a private registry token, into the VM's build sandbox;
  any build on the builder can read them, so keep it to a single-user
  workstation. Rotations arrive within a few minutes, and build scratch is
  emptied at boot. On a fresh machine switch once with `bootstrap = true`,
  then without.
- `developer` (Home Manager) also provides
  `nstdl.programs.pnpm.registryAuth`: `auth.ini` holds a `tokenHelper` that
  reads the token file on each pnpm run, never the token. Set the agenix
  secret's `owner` to the user.
- `proxmox-backup`: typed, credential-backed Proxmox Backup Client jobs and
  one-off client wrappers.
- `garage`: single-node Garage 2 object storage on loopback (S3 on
  `127.0.0.1:3900`) with declared buckets and keys. `garage-setup.service`
  creates them through the admin API and applies each key's permissions on
  the declared buckets exactly; services using a bucket should require it. It never
  deletes. The RPC secret, admin token and key secrets are files read as
  systemd credentials. A key's secret is fixed once imported: Garage cannot
  re-import a key ID even after deleting it, so a new secret needs a new key ID.
- `secrets`: ragenix plus agenix-rekey, with explicit host runtime ACLs.

NixOS hosts use an explicit locale policy. Its defaults are English messages,
German regional formatting, and the German `nodeadkeys` keyboard layout across
the console, display manager, and GNOME session. Override `hosts.<name>.locale`
when a host needs different language, formatting, or keyboard conventions.

nstdl is consumed through its flake-parts module. The exceptions are
`nixosModules.paradedb` and `nixosModules.garage`, exported for NixOS
configurations outside it, such as an application's VM test.

## Input sharing

`nstdl` owns and locks its Home Manager, nix-darwin, nix-index-database, Disko,
deploy-rs, and fenix inputs. It temporarily uses
[ragenix PR #168](https://github.com/yaxitech/ragenix/pull/168) for refreshed
Cargo and flake dependencies. After that PR is merged, return the ragenix input
to `github:yaxitech/ragenix` and update the lock file. Until then,
`nix flake update ragenix` picks up new PR commits. The defaults pair unstable
nixpkgs with Home Manager master. A consumer using those defaults only needs to
share `nixpkgs` and `flake-parts`, as shown above.

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
