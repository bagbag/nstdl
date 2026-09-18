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
  # the intended ownership. `linux-builder-start` wipes runtimeDir before every
  # launch, so delivery has to converge rather than run once at activation.
  runtimeDir = "/run/org.nixos.linux-builder";
  hostShareDir = "${runtimeDir}/certs";
  vmShareDir = "/etc/ssl/certs";

  deliverSecrets = pkgs.writeShellScript "nstdl-builder-sandbox-secrets" (
    ''
      set -u
      mkdir -p ${hostShareDir}
    ''
    + lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: secret: ''
        # agenix decrypts from its own launchd daemon, so at activation the
        # source can lag behind this job.
        for _ in $(seq 1 60); do
          [ -r "${secret.sourceFile}" ] && break
          sleep 1
        done

        if [ -r "${secret.sourceFile}" ]; then
          install -m 0400 "${secret.sourceFile}" "${hostShareDir}/${name}"
        else
          echo "nstdl: sandbox secret source '${secret.sourceFile}' is not readable; builder will not receive '${name}'" >&2
        fi
      '') cfg.sandboxSecrets
    )
  );
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

      Only the reference is declarative; the plaintext is decrypted on the host
      and copied in, never evaluated into a store path.

      `extra-sandbox-paths` grants the file to every sandboxed build on this
      builder, not only the one that needs it.
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
    nix.distributedBuilds = true;
    nix.settings.builders-use-substitutes = true;

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

      config = {
        # Sizing is free: it feeds the host-side runner and `vzvm.json` only,
        # leaving the guest closure substitutable. Verified by dry-run.
        virtualisation.cores = cfg.cores;
        virtualisation.darwin-builder.memorySize = cfg.memorySize;
        virtualisation.darwin-builder.diskSize = cfg.diskSize;

        # Everything below rewrites the guest's own closure; see `bootstrap`.
        # `mkIf` on each option rather than on the module as a whole, because
        # this is a `deferredModule` and a module is not an `mkIf` target.
        nix.settings = lib.mkIf (!cfg.bootstrap) {
          # Remote builds arrive as `nix-daemon --stdio` under sshd and so do
          # not inherit nix-daemon.service's environment; a systemd TMPDIR
          # override would miss them.
          build-dir = buildDir;

          # Trailing `?` marks the mount optional. Without it an undelivered
          # secret fails every build on this builder, not just the one needing
          # the credential.
          extra-sandbox-paths = lib.mapAttrsToList (_: secret: "${secret.path}?") cfg.sandboxSecrets;
        };

        systemd = lib.mkIf (!cfg.bootstrap) (
          lib.mkMerge [
            { tmpfiles.rules = [ "d ${buildDir} 0755 root root -" ]; }

            (lib.mkIf (cfg.sandboxSecrets != { }) {
              # Polled rather than a `systemd.path` unit: virtiofs delivers no
              # host-side inotify events to the guest, so no watch would see the
              # host write. Polling also picks up rotated credentials.
              timers.nstdl-sandbox-secrets = {
                description = "Poll for nstdl sandbox secrets delivered from the host";
                wantedBy = [ "timers.target" ];
                timerConfig = {
                  OnBootSec = "20s";
                  OnUnitActiveSec = "2min";
                };
              };

              services.nstdl-sandbox-secrets = {
                description = "Place nstdl sandbox secrets delivered from the host";
                # Also at boot, so a secret already in the share is in place
                # before the first build rather than up to OnBootSec later.
                wantedBy = [ "multi-user.target" ];
                before = [
                  "nix-daemon.service"
                  "sshd.service"
                ];
                unitConfig.ConditionPathIsDirectory = vmShareDir;
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
          ]
        );
      };
    };

    # RunAtLoad covers activation; WatchPaths covers every recreation of
    # runtimeDir, which a VM launch or host reboot performs.
    launchd = lib.mkIf (cfg.sandboxSecrets != { } && !cfg.bootstrap) {
      daemons.nstdl-builder-sandbox-secrets.serviceConfig = {
        ProgramArguments = [ "${deliverSecrets}" ];
        RunAtLoad = true;
        WatchPaths = [ runtimeDir ];
        StandardErrorPath = "/var/log/nstdl-builder-sandbox-secrets.log";
      };
    };
  };
}
