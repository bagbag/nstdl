{ config, lib, ... }:

let
  cfg = config.services.nstdl.systemd.services;

  enabled = lib.filterAttrs (_: unit: unit.sandbox.enable) cfg;

  # The fully restricted preset. `relax` names keys of this set directly, so the
  # option's type is derived from it and a typo fails evaluation.
  #
  # List-valued entries are the ones `extend` widens: kept as lists so
  # extending is a concatenation, and rendered as lists (below), so a
  # `~`-prefixed `SystemCallFilter` deny entry lands on its own line.
  maximal = {
    NoNewPrivileges = true;
    CapabilityBoundingSet = [ ];
    AmbientCapabilities = [ ];

    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectProc = "invisible";
    ProcSubset = "pid";
    PrivateTmp = true;
    PrivateDevices = true;
    PrivateMounts = true;

    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;

    LockPersonality = true;
    RemoveIPC = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    MemoryDenyWriteExecute = true;
    UMask = "0077";

    RestrictAddressFamilies = [ "AF_UNIX" ];
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" ];
    SystemCallErrorNumber = "EPERM";
  };

  # Only the capability sets are joined into one string: NixOS renders a list
  # as repeated assignments, and for these two an empty list would emit no
  # directive at all — unrestricted — where the empty string denies
  # everything. Every other list-valued directive is left as a list. This
  # matters for `SystemCallFilter`: systemd recognizes a leading `~`
  # (inversion) only as the first character of an assignment, so a joined
  # "@system-service ~@privileged" silently drops the deny, where repeated
  # `SystemCallFilter=` lines compose correctly, `~` entries included.
  renderList = lib.concatStringsSep " ";
  capabilitySets = [
    "CapabilityBoundingSet"
    "AmbientCapabilities"
  ];

  presetFor =
    sandbox:
    let
      # `relax` is applied to the preset before `extend` layers onto it, so a
      # directive that is both relaxed and extended replaces the baseline
      # instead of dropping the extension. Hence: extend only adds entries
      # (for `SystemCallFilter`, a `~`-prefixed entry among them denies),
      # relax only drops, both replace.
      base = removeAttrs maximal sandbox.relax;

      # systemd grants ambient capabilities out of the bounding set and drops
      # any that are not in it, so naming one ambient implies the bound.
      extend = sandbox.extend // {
        CapabilityBoundingSet = sandbox.extend.CapabilityBoundingSet ++ sandbox.extend.AmbientCapabilities;
      };

      merged =
        base
        // lib.mapAttrs (name: added: (base.${name} or [ ]) ++ added) (
          lib.filterAttrs (_: added: added != [ ]) extend
        );
    in
    # `mkOptionDefault`, a weaker priority than `mkDefault`, so this is a floor
    # rather than an opinion: any definition on the target unit wins, including
    # another module's `mkDefault`. Two `mkDefault`s would instead conflict.
    lib.mapAttrs (_: lib.mkOptionDefault) (
      lib.mapAttrs (
        name: value: if lib.isList value && lib.elem name capabilitySets then renderList value else value
      ) merged
    );

  # A unit name that matches nothing is not an error: `systemd.services` accepts
  # any name, so the typo silently produces a hardened unit with no ExecStart
  # instead of hardening the intended one. `script` lands in `serviceConfig` too
  # (nixos/lib/systemd-unit-options.nix), so only units supplied through
  # `systemd.packages` legitimately lack it — hence a warning, not an assertion.
  unresolved = lib.attrNames (
    lib.filterAttrs (name: _: !(config.systemd.services.${name}.serviceConfig ? ExecStart)) enabled
  );
in
{
  options.services.nstdl.systemd.services = lib.mkOption {
    default = { };
    description = ''
      nstdl settings applied to systemd services that already exist, addressed
      the same way as `systemd.services.<name>`.
    '';
    example = lib.literalExpression ''
      {
        myapp.sandbox = {
          enable = true;
          relax = [ "MemoryDenyWriteExecute" ];
          extend.RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        };
      }
    '';
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options.sandbox = {
            enable = lib.mkEnableOption ''
              systemd sandboxing of `systemd.services.${name}`.

              Deny by default: the service is assumed to need no network, no
              devices, no writable filesystem, no capabilities and no
              executable memory. `relax` drops directives from that preset and
              `extend` adds entries to the ones that take a list — for
              `SystemCallFilter`, a `~`-prefixed entry denies instead of
              widening.

              Applied at `mkOptionDefault`, below `mkDefault`, so any directive
              the unit sets itself wins and this only fills the gaps. Listing a
              service without setting this leaves it completely untouched
            '';

            relax = lib.mkOption {
              type = lib.types.listOf (lib.types.enum (lib.attrNames maximal));
              default = [ ];
              example = [
                "MemoryDenyWriteExecute"
                "ProcSubset"
              ];
              description = ''
                Directives dropped from the preset, named exactly as systemd
                names them, so what is being given up is unambiguous. An
                unknown name fails evaluation.

                The two that most often have to go:

                - `MemoryDenyWriteExecute` — every JIT runtime needs memory
                  that is writable and executable at once: V8 and therefore
                  Node, the JVM, .NET. Such a service will not start with it.
                - `ProcSubset` — the preset sets `pid`, hiding /proc entries
                  like `meminfo` and `cpuinfo` that language runtimes read to
                  size their heap and thread pools.

                A directive named here *and* in `extend` is replaced rather
                than dropped: the preset's own value is discarded and only the
                `extend` entries remain.
              '';
            };

            extend = lib.mkOption {
              default = { };
              description = ''
                Entries added to the list-valued directives, on top of whatever
                `relax` left of the preset. Options are named after the
                directives themselves, so an unknown one fails evaluation.
              '';
              example = lib.literalExpression ''
                {
                  RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
                  AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
                }
              '';
              type = lib.types.submodule {
                options = {
                  RestrictAddressFamilies = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [ ];
                    example = [
                      "AF_INET"
                      "AF_INET6"
                    ];
                    description = ''
                      Address families beyond the preset's `AF_UNIX`. Anything
                      reaching the network needs `AF_INET` and `AF_INET6`;
                      enumerating interfaces or routes needs `AF_NETLINK`.
                    '';
                  };

                  AmbientCapabilities = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [ ];
                    example = [ "CAP_NET_BIND_SERVICE" ];
                    description = ''
                      Capabilities the process actually holds, and the option to
                      reach for on a service running as a non-root `User=`.
                      Each is added to `CapabilityBoundingSet` as well, since
                      systemd grants ambient capabilities out of the bounding
                      set.
                    '';
                  };

                  CapabilityBoundingSet = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [ ];
                    example = [ "CAP_SYS_ADMIN" ];
                    description = ''
                      Raises the ceiling only; it grants nothing on its own. Use
                      it for a service that starts as root and drops privileges
                      itself, or one that sets its own ambient set. Otherwise
                      name the capability under `AmbientCapabilities`.
                    '';
                  };

                  SystemCallFilter = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [ ];
                    example = [ "@chown" ];
                    description = ''
                      Groups beyond the preset's `@system-service`, or, prefixed
                      with `~`, calls denied on top of it. Entries apply in the
                      order given — a `~`-prefixed group followed by an
                      unprefixed call re-allows that call.
                    '';
                  };

                  ReadWritePaths = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [ ];
                    description = ''
                      Paths exempted from `ProtectSystem = "strict"`. A service
                      with a `StateDirectory` does not need its state listed.
                    '';
                  };
                };
              };
            };
          };
        }
      )
    );
  };

  config = lib.mkIf (enabled != { }) {
    systemd.services = lib.mapAttrs (_: unit: { serviceConfig = presetFor unit.sandbox; }) enabled;

    warnings = lib.optional (unresolved != [ ]) ''
      services.nstdl.systemd.services: sandboxing is enabled for ${
        lib.concatMapStringsSep ", " (n: "'${n}'") unresolved
      }, which set no ExecStart. Either a name does not match an existing
      unit — in which case an empty hardened unit has just been created — or the
      unit comes from systemd.packages, where this warning does not apply.
    '';
  };
}
