{ lib, ... }:
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
      - self:                   Required. The final flake's `self` reference.
      - inputs:                 Required. The flake's `inputs` set.
      - src:                    Required. The path to the flake's src (usually `./.`).
      - hosts:               Required. The attrset defining all hosts and their data.
      - specialArgs:            Optional. Extra specialArgs to pass to all modules.
      - deployUser:             Optional. The default SSH user for deploy-rs (defaults to "root").
      - environmentsPath:       Optional. Path within `src` to find environment modules.
      - diskoConfigurationsPath:Optional. Path within `src` to find disko modules.
  */
  mkFlake =
    {
      self,
      inputs,
      src,
      hosts,
      specialArgs ? { },
      deployUser ? "root",
      environmentsPath ? "/modules/environments",
      diskoConfigurationsPath ? "/modules/disko",
      ... # Pass through any other arguments to snowfall-lib.mkFlake
    }@args:
    let
      # Remove arguments consumed by this function so they aren't passed to snowfall-lib
      argsRest = lib.removeAttrs args [
        "self"
        "inputs"
        "src"
        "hosts"
        "specialArgs"
        "deployUser"
        "environmentsPath"
        "diskoConfigurationsPath"
      ];

      # Helper to load all .nix files from a directory into an attribute set.
      # The filename (without .nix) becomes the attribute name.
      loadModulesFromDir =
        path:
        let
          fullPath = src + path;
          files = builtins.readDir fullPath;
        in
        lib.mapAttrs' (
          name: type:
          if type == "regular" && lib.hasSuffix ".nix" name then
            lib.nameValuePair (lib.removeSuffix ".nix" name) (fullPath + "/${name}")
          else
            # Skip sub-directories and non-nix files
            lib.nameValuePair "" null
        ) files;

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
            throw "Host '${hostName}' specifies ${configType} '${configName}', but no corresponding module was found at ${configsPath}/${configName}.nix"
        else
          [ ];

      # Dynamically load configurations from their respective directories.
      environmentConfigurations = loadModulesFromDir environmentsPath;
      diskoConfigurations = loadModulesFromDir diskoConfigurationsPath;

      # Process hosts to generate a more detailed `processedHosts` set.
      processedHosts = lib.mapAttrs (
        key: data:
        let
          hostname = if data ? "hostname" then data.hostname else key;
          ipv4Address = if data ? "ipv4" then lib.head (lib.splitString "/" data.ipv4) else null;
          ipv6Address = if data ? "ipv6" then lib.head (lib.splitString "/" data.ipv6) else null;
        in
        data
        // {
          inherit hostname ipv4Address ipv6Address;
          host =
            if data ? "host" then
              data.host
            else if ipv6Address != null then
              ipv6Address
            else
              ipv4Address;
        }
      ) hosts;

      # Filter out hosts that are explicitly marked not for deployment.
      deployableHosts = lib.filterAttrs (
        _name: host: !(host ? "deploy" && host.deploy == false)
      ) processedHosts;

      # Call snowfall-lib to generate the core flake structure.
      sfFlake = inputs.snowfall-lib.mkFlake (
        lib.mkMerge [
          ({
            inherit inputs src specialArgs;

            systems.modules.nixos = with inputs; [
              disko.nixosModules.disko
              ragenix.nixosModules.default
            ];

            homes.modules = with inputs; [
              nix-index-database.homeModules.nix-index
            ];

            # Configure each host based on the `processedHosts` set.
            systems.hosts = lib.mapAttrs (hostname: hostConfig: {
              # These are host-specific specialArgs. Snowfall-lib will merge the
              # global specialArgs into these.
              specialArgs = {
                inherit self hostConfig;
                hosts = processedHosts;
              };

              modules =
                [
                  # Expose hostConfig to modules via `config.nstdl.hostConfig`.
                  ({ config.nstdl.hostConfig = hostConfig; })
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
          })
          # The user's passthrough configuration
          argsRest
        ]
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
