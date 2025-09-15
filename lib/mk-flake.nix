{
  lib,
  inputs,
  selfNixosModules,
  ...
}:
{
  /*
    A wrapper around snowfall-lib.mkFlake to reduce boilerplate for a common setup.

    This function automatically:
    - Scans for and loads environment and disko configurations dynamically.
    - Processes `hosts` to add useful attributes like `hostname`, `ipv4Address`, etc.
    - Creates `processedHosts` and `deployableHosts` sets.
    - Configures snowfall-lib with common modules and specialArgs for each host.
    - Exposes NixOS configurations at the top level for tools like nixos-anywhere.
    - Generates `deploy-rs` configuration and checks.

    Arguments:
      - self:                    Required. The final flake's `self` reference.
      - inputs:                  Required. The flake's `inputs` set.
      - src:                     Required. The path to the flake's src (usually `./.`).
      - hosts:                   Required. The attrset defining all hosts and their data.
      - specialArgs:             Optional. Extra specialArgs to pass to all modules.
      - deployUser:              Optional. The default SSH user for deploy-rs (defaults to "root").
      - environmentsPath:        Optional. Path within `src` to find environment modules.
      - diskoConfigurationsPath: Optional. Path within `src` to find disko modules.
  */
  mkFlake =
    {
      self,
      inputs,
      src,
      hosts,
      specialArgs ? { },
      deployUser ? "root",
      environmentsPath ? "modules/environments",
      diskoConfigurationsPath ? "modules/disko",
      ... # Pass through any other arguments to snowfall-lib.mkFlake
    }@args:
    let
      nstdlArgs = [
        "self"
        "hosts"
        "deployUser"
        "environmentsPath"
        "diskoConfigurationsPath"
      ];

      snowfallArgs = lib.removeAttrs args nstdlArgs;

      # Helper to load all .nix files from a directory into an attribute set.
      # The filename (without .nix) becomes the attribute name.
      loadModulesFromDir =
        path:
        let
          fullPath = lib.path.append src path;
        in
        if builtins.pathExists fullPath then
          let
            files = builtins.readDir fullPath;
            nixFiles = lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) files;
          in
          if nixFiles == { } then
            lib.trace "Warning: Directory '${toString fullPath}' exists but contains no .nix files." { }
          else
            lib.mapAttrs' (
              name: _: lib.nameValuePair (lib.removeSuffix ".nix" name) (fullPath + "/${name}")
            ) nixFiles
        else
          lib.trace
            "Warning: Path '${toString fullPath}' does not exist. No modules will be loaded from this path."
            { };

      # Helper to get a module if it exists, or throw an error.
      # Returns a list containing the module path, or an empty list if not specified.
      getValidatedModule =
        {
          hostName,
          hostConfig,
          configType,
          availableConfigs,
          configsPath,
        }:
        if hostConfig ? "${configType}" then
          let
            configName = hostConfig."${configType}";
          in
          if availableConfigs ? "${configName}" then
            [ (availableConfigs."${configName}") ]
          else
            throw "Host '${hostName}' specifies ${configType} '${configName}', but no corresponding module was found at ${toString src}/${configsPath}/${configName}.nix. Available ${configType}s are: [${lib.concatStringsSep ", " (lib.attrNames availableConfigs)}]"
        else
          [ ];

      # Dynamically load configurations from their respective directories.
      environmentConfigurations = loadModulesFromDir environmentsPath;
      diskoConfigurations = loadModulesFromDir diskoConfigurationsPath;

      # Process hosts to generate a more detailed `processedHosts` set.
      processedHosts = lib.mapAttrs (
        key: data:
        let
          identifier = key;
          hostname = data.hostname or key;
          ipv4Address = if data ? "ipv4" then lib.head (lib.splitString "/" data.ipv4) else null;
          ipv6Address = if data ? "ipv6" then lib.head (lib.splitString "/" data.ipv6) else null;
        in
        data
        // {
          inherit
            identifier
            hostname
            ipv4Address
            ipv6Address
            ;
          host = data.host or ipv6Address;
        }
      ) hosts;

      # Filter out hosts that are explicitly marked not for deployment.
      deployableHosts = lib.filterAttrs (
        _name: host: !(host ? "deploy" && host.deploy == false)
      ) processedHosts;

      # Call snowfall-lib to generate the core flake structure.
      sfFlake = inputs.snowfall-lib.mkFlake (
        let
          baseConfig = snowfallArgs;

          nstdlSystemModules =
            with inputs;
            [
              # External dependencies provided by the user
              disko.nixosModules.disko
              ragenix.nixosModules.default
              home-manager.nixosModules.home-manager

              # Internal base module
              ../modules/nixos/base
            ]
            ++ selfNixosModules;

          nstdlHomeModules = with inputs; [
            nix-index-database.homeModules.nix-index
            ../modules/home-manager/common.nix
          ];

          nstdlHosts = lib.mapAttrs (hostname: hostConfig: {
            specialArgs = (snowfallArgs.specialArgs or { }) // {
              inherit self;
              hosts = processedHosts;
              hostConfig = hostConfig;
            };

            modules = [
              # Expose hostConfig to modules via `config.nstdl.hostConfig`.
              ({ config.nstdl.hostConfig = hostConfig; })

              # Set a sensible default for the secrets base directory.
              # This allows users to place secrets in `./secrets/` or
              # `./secrets/<environment>/` and have them be discovered automatically.
              (
                { lib, ... }:
                {
                  nstdl.age.secretsBaseDir = lib.mkDefault (
                    let
                      secretsPath = lib.path.append src "secrets";
                    in
                    if hostConfig.environment != null then
                      lib.path.append secretsPath hostConfig.environment
                    else
                      secretsPath
                  );
                }
              )
            ]
            # Dynamically add the environment module if specified for the host.
            ++ (getValidatedModule {
              hostName = hostname;
              inherit hostConfig;
              configType = "environment";
              availableConfigs = environmentConfigurations;
              configsPath = environmentsPath;
            })

            # Dynamically add the disko module if specified for the host.
            ++ (getValidatedModule {
              hostName = hostname;
              inherit hostConfig;
              configType = "disko";
              availableConfigs = diskoConfigurations;
              configsPath = diskoConfigurationsPath;
            });
          }) processedHosts;

        in
        # Deeply merge the user-provided config with the nstdl-generated config.
        baseConfig
        // {
          systems = (baseConfig.systems or { }) // {
            modules = (baseConfig.systems.modules or { }) // {
              nixos = (baseConfig.systems.modules.nixos or [ ]) ++ nstdlSystemModules;
            };

            hosts = nstdlHosts;
          };

          homes = (baseConfig.homes or { }) // {
            modules = (baseConfig.homes.modules or [ ]) ++ nstdlHomeModules;
          };
        }
      );

      # Create top-level aliases for each nixosConfiguration.
      # This is useful for tools like nixos-anywhere.
      nixosConfigurationsAliases = lib.mapAttrs (
        hostname: _: sfFlake.nixosConfigurations."${hostname}"
      ) hosts;

      # Generate the configuration for deploy-rs.
      deployConfig = {
        nodes = lib.mapAttrs (name: host: {
          hostname = host.host;
          sshUser = host.deployUser or deployUser;
          fastConnection = true;

          profiles.system = {
            user = "root";
            path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations."${name}";
          };
        }) deployableHosts;
      };

    in
    # Combine the snowfall-lib result, the aliases, and our generated outputs.
    sfFlake
    // nixosConfigurationsAliases
    // {
      # Expose our processed host lists for other tools.
      inherit processedHosts deployableHosts;

      # Expose the deploy-rs configuration.
      deploy = deployConfig;

      # Add checks for deploy-rs.
      checks =
        (sfFlake.checks or { })
        // (builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) inputs.deploy-rs.lib);
    };
}
