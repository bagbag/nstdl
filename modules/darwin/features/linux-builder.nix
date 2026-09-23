{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nstdl.linuxBuilder;

  # `/` in the builder VM is tmpfs, so Nix's default build directory is RAM.
  # /nix/.rw-store is the VM's only disk-backed writable filesystem.
  buildDir = "/nix/.rw-store/nix-build";

  # hostShareDir is shared into the VM at vmShareDir under virtiofs tag
  # `certs`, the only writable host -> VM channel the builder exposes. Used as
  # transport only; a unit in the VM copies each secret to its real path with
  # the intended ownership. The VM runner creates hostShareDir and upstream
  # deletes runtimeDir when the VM stops, so delivery converges on a schedule
  # and skips while no VM is running.
  runtimeDir = "/run/org.nixos.linux-builder";
  hostShareDir = "${runtimeDir}/certs";
  vmShareDir = "/etc/ssl/certs";
in
{
  options.nstdl.linuxBuilder.cores = lib.mkOption {
    type = lib.types.ints.positive;
    default = 8;
    description = ''
      Virtual CPUs for the builder VM.

      Upstream defaults to 1, which serializes Rust builds already slowed by
      Rosetta translation.
    '';
  };

  options.nstdl.linuxBuilder.memorySize = lib.mkOption {
    type = lib.types.ints.positive;
    default = 8192;
    description = ''
      Builder VM memory in MiB.

      Only has to hold compiler processes, not build scratch, since `build-dir`
      points at the data disk. If a build is OOM-killed, lower `maxJobs` before
      raising this: `cores` already saturates the VM.
    '';
  };

  options.nstdl.linuxBuilder.diskSize = lib.mkOption {
    type = lib.types.ints.positive;
    default = 131072;
    description = ''
      Builder VM data disk in MiB, holding the VM's Nix store and build scratch.

      Sparse, so it costs only what the guest writes — but it never shrinks
      back below its high-water mark. Created once, so raising this takes
      effect only after deleting `nixos.qcow2` in the builder's working
      directory.
    '';
  };

  options.nstdl.linuxBuilder.maxJobs = lib.mkOption {
    type = lib.types.ints.positive;
    default = 2;
    description = "Derivations the builder runs concurrently.";
  };

  options.nstdl.linuxBuilder.supportedFeatures = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [
      "benchmark"
      "big-parallel"
      "nixos-test"
    ];
    example = [
      "benchmark"
      "big-parallel"
      "kvm"
      "nixos-test"
    ];
    description = ''
      Features advertised to Nix for this builder. A derivation requesting a
      feature that is not listed will not be scheduled here.

      Two deliberate differences from the upstream default of
      `[ "kvm" "benchmark" "big-parallel" ]`:

      - `kvm` is absent. The VM runs without
        `virtualisation.vz.nestedVirtualization`, so the guest has no
        `/dev/kvm`. Advertising it means every derivation requiring kvm is
        dispatched here and then fails.
      - `nixos-test` is present. `qemu.forceAccel` defaults to false, so a
        NixOS VM test falls back to TCG and runs here unaccelerated, provided
        the test also drops `kvm` from its own `requiredFeatures`:
        `requiredFeatures.kvm = lib.mkForce false`. Prefer an aarch64-linux
        test — under TCG an x86_64 guest means full cross-architecture
        emulation, while aarch64-on-aarch64 does not.
    '';
  };

  options.nstdl.linuxBuilder.bootstrap = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Run the builder with an unmodified guest configuration.

      Customising the VM's NixOS config makes its system closure novel, so it
      is no longer substituted wholesale from the binary cache and has to be
      built — and the derivations involved set `allowSubstitutes = false`, so
      building them needs an aarch64-linux machine. On a fresh host the only
      one available is the VM that does not exist yet.

      Set this for the first `darwin-rebuild switch` on a new machine, then
      unset it and switch again: the VM from the first switch builds its own
      customised closure for the second.

      `cores`, `memorySize` and `diskSize` still apply while bootstrapping —
      they only affect the host-side runner. `build-dir` and `sandboxSecrets`
      take effect from the second switch.
    '';
  };

  options.nstdl.linuxBuilder.sandboxSecrets = lib.mkOption {
    default = { };
    description = ''
      Secrets delivered from this host into the Linux builder VM and granted to
      its build sandbox, for fixed-output derivations that authenticate against
      a private registry.

      Any build on the builder can read these secrets, so this suits a
      single-user workstation builder, not one shared with untrusted builds.

      Only the reference is declarative; the plaintext is decrypted on the host
      and copied in, never evaluated into a store path.

      Rotation reaches a running VM within a few minutes.
    '';
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            sourceFile = lib.mkOption {
              type = lib.types.str;
              description = ''
                Absolute path on this host holding the plaintext secret,
                typically `config.age.secrets.<name>.path`. A string, not a Nix
                path: a path literal would copy the secret into the store.
              '';
            };

            path = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/nix-builder-credentials/${name}";
              description = "Absolute path the secret is placed at inside the VM.";
            };

            group = lib.mkOption {
              type = lib.types.str;
              default = "nixbld";
              description = "Group owning the file inside the VM. Build users need read access.";
            };

            mode = lib.mkOption {
              type = lib.types.str;
              default = "0440";
              description = "Mode of the file inside the VM.";
            };
          };
        }
      )
    );
  };

  config = {
    nix.linux-builder = {
      enable = true;
      package = pkgs.darwin.linux-builder-vz;
      # aarch64-linux is the VM's own architecture and x86_64-linux runs under
      # Rosetta. Registering both is not optional once `config` below deviates
      # from upstream: the VM's own system closure stops being substitutable,
      # and building it needs an aarch64-linux builder.
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      maxJobs = cfg.maxJobs;

      supportedFeatures = cfg.supportedFeatures;

      config = lib.mkMerge [
        {
          # Sizing is free: it feeds the host-side runner and `vzvm.json` only,
          # leaving the guest closure substitutable.
          virtualisation.cores = cfg.cores;
          virtualisation.darwin-builder.memorySize = cfg.memorySize;
          virtualisation.darwin-builder.diskSize = cfg.diskSize;
        }

        # Everything below rewrites the guest's own closure; see `bootstrap`.
        (lib.mkIf (!cfg.bootstrap) {
          nix.settings = {
            # The default, /nix/var/nix/builds, is on the tmpfs root.
            build-dir = buildDir;

            # Trailing `?` marks the mount optional. Without it an undelivered
            # secret fails every build on this builder, not just the one
            # needing the credential.
            extra-sandbox-paths = lib.mapAttrsToList (_: secret: "${secret.path}?") cfg.sandboxSecrets;
          };

          # `D!` empties it at boot: the disk persists, and builds interrupted
          # by a VM stop leave their scratch behind.
          systemd.tmpfiles.rules = [ "D! ${buildDir} 0755 root root -" ];
        })

        (lib.mkIf (!cfg.bootstrap && cfg.sandboxSecrets != { }) {
          # Polled rather than a `systemd.path` unit: virtiofs delivers no
          # host-side inotify events to the guest, so no watch would see the
          # host write.
          systemd.timers.nstdl-sandbox-secrets = {
            description = "Poll for nstdl sandbox secrets delivered from the host";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = "20s";
              OnUnitActiveSec = "2min";
            };
          };

          systemd.services.nstdl-sandbox-secrets = {
            description = "Place nstdl sandbox secrets delivered from the host";
            # Also at boot, so a secret already in the share is in place
            # before the first build rather than up to OnBootSec later.
            wantedBy = [ "multi-user.target" ];
            before = [ "nix-daemon.service" ];
            # No RemainAfterExit: the timer must be able to run it again.
            serviceConfig.Type = "oneshot";
            script = lib.concatStringsSep "\n" (
              lib.mapAttrsToList (name: secret: ''
                # Silent unless something changed; this runs on a timer.
                if [ -s "${vmShareDir}/${name}" ]; then
                  # sha256sum, not cmp: diffutils is not on the unit PATH.
                  if [ "$(sha256sum < "${vmShareDir}/${name}")" != "$(sha256sum < "${secret.path}" 2>/dev/null)" ]; then
                    install -D -m ${secret.mode} -o root -g ${secret.group} \
                      "${vmShareDir}/${name}" "${secret.path}"
                    echo "nstdl: installed sandbox secret '${name}'"
                  fi
                elif [ ! -e "${secret.path}" ]; then
                  echo "nstdl: sandbox secret '${name}' has not been delivered by the host" >&2
                fi
              '') cfg.sandboxSecrets
            );
          };
        })
      ];
    };

    # WatchPaths delivers as soon as a VM launch recreates runtimeDir;
    # StartInterval picks up rotated secrets and agenix decrypting late.
    launchd = lib.mkIf (cfg.sandboxSecrets != { } && !cfg.bootstrap) {
      daemons.nstdl-builder-sandbox-secrets = {
        script = ''
          [ -d ${hostShareDir} ] || exit 0
        ''
        + lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: secret: ''
            if [ -r "${secret.sourceFile}" ]; then
              install -m 0400 "${secret.sourceFile}" "${hostShareDir}/${name}"
            else
              echo "nstdl: sandbox secret source '${secret.sourceFile}' is not readable; builder will not receive '${name}'" >&2
            fi
          '') cfg.sandboxSecrets
        );
        serviceConfig = {
          RunAtLoad = true;
          WatchPaths = [ runtimeDir ];
          StartInterval = 120;
          StandardErrorPath = "/var/log/nstdl-builder-sandbox-secrets.log";
        };
      };
    };
  };
}
