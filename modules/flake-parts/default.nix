{ inputs }:
{
  config,
  lib,
  nstdlDeployment,
  nstdlNetwork,
  nstdlSecrets,
  nstdlStorage,
  ...
}:
let
  inherit (lib) mkOption types;
  flakeConfig = config;

  selectProfiles =
    profiles: requested:
    map (
      name:
      if profiles ? ${name} then
        profiles.${name}
      else
        throw "nstdl: unknown profile '${name}'. Available profiles: ${lib.concatStringsSep ", " (lib.attrNames profiles)}"
    ) requested;

  hostProfiles =
    host:
    [ host.role ]
    ++ host.features
    ++ lib.optional (
      host.platform == "nixos"
      && (host.accounts.users != { } || host.accounts.root.enable || host.accounts.extraSshUsers != [ ])
    ) "accounts";

  hasFeature = feature: host: lib.elem feature host.features;

  homeModulesFor = features: selectProfiles config.nstdl.profiles.home features;

  sshKeysForPeople =
    people: lib.concatMap (person: config.nstdl.accounts.people.${person}.sshKeys) people;

  homeModuleFor =
    platform: host:
    let
      homeUsers = lib.filterAttrs (_: user: user.home.enable) host.accounts.users;
    in
    {
      home-manager.users = lib.mapAttrs (name: user: {
        imports = homeModulesFor user.home.features;
        home = {
          username = name;
          homeDirectory =
            if user.home.homeDirectory != null then
              user.home.homeDirectory
            else if platform == "darwin" then
              "/Users/${name}"
            else
              "/home/${name}";
          stateVersion = user.home.stateVersion;
        };
      }) homeUsers;
    };

  hostModuleFor = host: {
    imports = [ (nstdlSecrets.moduleFor host) ];
    nstdl = {
      hostName = host.hostName;
      domain = host.domain;
      user = {
        name = host.accounts.primary;
        authorizedKeys = sshKeysForPeople (
          lib.attrByPath [ host.accounts.primary "people" ] [ ] host.accounts.users
        );
      };
    }
    // lib.optionalAttrs (host.platform == "nixos") {
      virtualization = host.virtualization;
    }
    //
      lib.optionalAttrs
        (
          host.platform == "nixos"
          && (host.accounts.users != { } || host.accounts.root.enable || host.accounts.extraSshUsers != [ ])
        )
        {
          accounts = {
            role = host.role;
            primary = host.accounts.primary;
            extraSshUsers = host.accounts.extraSshUsers;
            root = {
              enable = host.accounts.root.enable;
              sshKeys = sshKeysForPeople host.accounts.root.sshPeople;
            };
            users = lib.mapAttrs (name: user: {
              inherit (user) administrator;
              sshKeys = sshKeysForPeople user.people;
            }) host.accounts.users;
          };
        };
  };

  nixosConfigurationFor =
    host:
    inputs.nixpkgs.lib.nixosSystem {
      system = host.system;
      modules =
        nstdlStorage.importsFor inputs host
        ++ selectProfiles config.nstdl.profiles.nixos (hostProfiles host)
        ++ host.extraModules
        ++ [
          (hostModuleFor host)
          (nstdlStorage.moduleFor host)
          (nstdlNetwork.moduleFor host)
          inputs.home-manager.nixosModules.home-manager
          {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
            };
          }
          (homeModuleFor "nixos" host)
          { system.stateVersion = host.systemStateVersion; }
        ];
    };

  darwinConfigurationFor =
    host:
    inputs.nix-darwin.lib.darwinSystem {
      system = host.system;
      modules =
        selectProfiles config.nstdl.profiles.darwin (hostProfiles host)
        ++ host.extraModules
        ++ [
          (hostModuleFor host)
          inputs.home-manager.darwinModules.home-manager
          {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
            };
          }
          (homeModuleFor "darwin" host)
          { system.stateVersion = host.systemStateVersion; }
        ];
    };

  homeConfigurationFor =
    home:
    inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = import inputs.nixpkgs {
        system = home.system;
        config.allowUnfree = true;
      };
      modules =
        selectProfiles config.nstdl.profiles.home home.features
        ++ home.extraModules
        ++ [
          {
            home = {
              username = home.userName;
              homeDirectory = home.homeDirectory;
              stateVersion = home.stateVersion;
            };
          }
        ];
    };

  validHosts = builtins.seq nstdlSecrets.validateAccessHosts (
    lib.mapAttrs (
      name: host:
      if host.platform == "darwin" && host.role != "workstation" then
        throw "nstdl Darwin host '${name}' must use the workstation role"
      else if host.platform == "darwin" && host.virtualization != "none" then
        throw "nstdl Darwin host '${name}' must use virtualization = \"none\""
      else
        builtins.seq (nstdlStorage.validateHost name host) (
          builtins.seq (nstdlNetwork.validateHost name host) (
            builtins.seq (nstdlDeployment.validateHost name host) (
              builtins.seq (nstdlSecrets.validateHostAccess name host) (
                if
                  host.platform == "nixos"
                  && !lib.all (person: config.nstdl.accounts.people ? ${person}) (
                    host.accounts.root.sshPeople
                    ++ lib.concatMap (user: user.people) (lib.attrValues host.accounts.users)
                  )
                then
                  throw "nstdl host '${name}' references an unknown accounts.people entry"
                else
                  nstdlSecrets.validateHost name host
              )
            )
          )
        )
    ) config.nstdl.hosts
  );
in
{
  imports = [
    inputs.flake-parts.flakeModules.nixosConfigurations
    inputs.agenix-rekey.flakeModule
    ./features/core.nix
    ./features/server.nix
    ./features/workstation.nix
    (import ./features/desktop-apps.nix { inherit inputs; })
    ./features/accounts.nix
    (import ./features/developer.nix { inherit inputs; })
    ./features/podman.nix
    ./features/postgresql.nix
    ./features/proxmox-backup.nix
    ./features/remote-access.nix
    (import ./features/capabilities.nix { inherit inputs; })
    ./storage.nix
    ./network.nix
    ./deployment.nix
    ./secrets.nix
    (import ./features/secrets.nix { inherit inputs; })
  ];

  options.nstdl = {
    accounts.people = mkOption {
      type = types.attrsOf (
        types.submodule { options.sshKeys = mkOption { type = types.listOf types.str; }; }
      );
      default = { };
      description = "Reusable public SSH keys for managed people.";
    };
    profiles = {
      nixos = mkOption {
        type = types.attrsOf types.deferredModule;
        default = { };
        internal = true;
        description = "NixOS profile contributions registered by nstdl features.";
      };
      darwin = mkOption {
        type = types.attrsOf types.deferredModule;
        default = { };
        internal = true;
        description = "Darwin profile contributions registered by nstdl features.";
      };
      home = mkOption {
        type = types.attrsOf types.deferredModule;
        default = { };
        internal = true;
        description = "Home Manager profile contributions registered by nstdl features.";
      };
    };

    hosts = mkOption {
      default = { };
      description = "NixOS and nix-darwin hosts assembled by nstdl.";
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              name = mkOption {
                type = types.str;
                default = name;
                readOnly = true;
              };
              platform = mkOption {
                type = types.enum [
                  "nixos"
                  "darwin"
                ];
                description = "The configuration class for this host.";
              };
              system = mkOption {
                type = types.str;
                description = "Nix system identifier, such as x86_64-linux.";
              };
              role = mkOption {
                type = types.enum [
                  "server"
                  "workstation"
                ];
                description = "Exactly one host role.";
              };
              features = mkOption {
                type = types.listOf (
                  types.enum [
                    "developer"
                    "desktop-apps"
                    "podman"
                    "postgresql"
                    "proxmox-backup"
                    "remote-access"
                    "secrets"
                    "foreign-binaries" "container-development" "remote-desktop" "full-stack-developer" "office-suite"
                  ]
                );
                default = [ ];
                description = "Additive features layered over the host role.";
              };
              hostName = mkOption {
                type = types.str;
                default = name;
                description = "Network host name.";
              };
              domain = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Optional network domain.";
              };
              virtualization = mkOption {
                type = types.enum [
                  "none"
                  "qemu"
                  "vmware"
                ];
                default = "none";
                description = "NixOS guest environment whose supported agent nstdl enables.";
              };
              systemStateVersion = mkOption {
                type = types.anything;
                description = "Consumer-owned system.stateVersion.";
              };
              accounts = {
                primary = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                };
                root = {
                  enable = mkOption {
                    type = types.bool;
                    default = false;
                    description = "Allow explicit SSH-key-only break-glass root access.";
                  };
                  sshPeople = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    description = "Named people whose public SSH keys may access root.";
                  };
                };
                extraSshUsers = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                };
                users = mkOption {
                  type = types.attrsOf (
                    types.submodule (
                      { name, ... }:
                      {
                        options = {
                          people = mkOption {
                            type = types.listOf types.str;
                            default = [ name ];
                            description = "Named people whose public SSH keys may access this Unix account.";
                          };
                          administrator = mkOption {
                            type = types.bool;
                            default = false;
                          };
                          home = {
                            enable = mkOption {
                              type = types.bool;
                              default = false;
                            };
                            stateVersion = mkOption {
                              type = types.nullOr types.str;
                              default = null;
                            };
                            homeDirectory = mkOption {
                              type = types.nullOr types.str;
                              default = null;
                            };
                            features = mkOption {
                              type = types.listOf (
                                types.enum [
                                  "workstation"
                                  "developer"
                                  "desktop-apps"
                                  "javascript-development" "python-development" "native-development" "database-client" "developer-extras" "office-tools" "document-tools" "creative-media" "remote-desktop" "messaging" "syncthing" "gnome-extras" "vscode" "ai-agent-tools" "secret-admin" "full-stack-developer"
                                ]
                              );
                              default = [ ];
                            };
                          };
                        };
                      }
                    )
                  );
                  default = { };
                };
              };
              secrets.hostPubkey = mkOption {
                type = types.nullOr types.nonEmptyStr;
                default = null;
                description = "Public runtime recipient key for this host when the secrets feature is selected.";
              };
              storage = nstdlStorage.hostOption;
              network = nstdlNetwork.hostOption;
              deployment = nstdlDeployment.hostOptions;
              extraModules = mkOption {
                type = types.listOf types.deferredModule;
                default = [ ];
                description = "Host-local NixOS or Darwin modules.";
              };
            };
          }
        )
      );
    };

    homes = mkOption {
      default = { };
      description = "Standalone Home Manager configurations assembled by nstdl.";
      type = types.attrsOf (
        types.submodule {
          options = {
            system = mkOption { type = types.str; };
            userName = mkOption { type = types.str; };
            homeDirectory = mkOption { type = types.str; };
            stateVersion = mkOption { type = types.str; };
            features = mkOption {
              type = types.listOf (
                types.enum [
                  "workstation"
                  "developer"
                  "desktop-apps"
                  "javascript-development" "python-development" "native-development" "database-client" "developer-extras" "office-tools" "document-tools" "creative-media" "remote-desktop" "messaging" "syncthing" "gnome-extras" "vscode" "ai-agent-tools" "secret-admin" "full-stack-developer"
                ]
              );
              default = [ ];
            };
            extraModules = mkOption {
              type = types.listOf types.deferredModule;
              default = [ ];
            };
          };
        }
      );
    };
  };

  options.flake.darwinConfigurations = mkOption {
    type = types.lazyAttrsOf types.raw;
    default = { };
    description = "nix-darwin configurations, including nstdl-managed and consumer-managed hosts.";
  };

  config = {
    systems = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];

    perSystem =
      { config, system, ... }:
      {
        packages.agenix-rekey = config.agenix-rekey.package;
        apps.agenix-rekey = {
          type = "app";
          program = "${config.agenix-rekey.package}/bin/agenix";
        };
        checks = nstdlDeployment.checksFor {
          inherit inputs system;
          deploy = flakeConfig.flake.deploy;
        };
      };

    flake = {
      nixosConfigurations = lib.mapAttrs (_name: host: nixosConfigurationFor host) (
        lib.filterAttrs (_name: host: host.platform == "nixos") validHosts
      );

      darwinConfigurations = lib.mapAttrs (_name: host: darwinConfigurationFor host) (
        lib.filterAttrs (_name: host: host.platform == "darwin") validHosts
      );

      deploy.nodes = nstdlDeployment.nodesFor {
        inherit config inputs;
        hosts = validHosts;
      };

      homeConfigurations = lib.mapAttrs (_name: home: homeConfigurationFor home) config.nstdl.homes;
    };
  };
}
