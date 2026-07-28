{
  config,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  hasFeature = feature: host: lib.elem feature host.features;

  canonicalRecipient =
    recipient:
    let
      words = lib.filter (word: word != "") (lib.splitString " " recipient);
    in
    if lib.hasPrefix "ssh-" recipient then
      lib.concatStringsSep " " (lib.take 2 words)
    else
      builtins.head words;

  isRecipient =
    recipient:
    builtins.match "^(age1[0-9a-z]{58}|ssh-[A-Za-z0-9-]+ [A-Za-z0-9+/]{40,}={0,2})( .*)?$" recipient
    != null;

  secretPolicy = config.nstdl.secrets;

  configuredSecretHosts = lib.filter (
    host: hasFeature "secrets" host && host.secrets.hostPubkey != null
  ) (lib.attrValues config.nstdl.hosts);

  runtimeRecipients = map (host: canonicalRecipient host.secrets.hostPubkey) configuredSecretHosts;

  secretAccessHostNames = lib.unique (
    lib.concatMap (secret: lib.attrNames secret.access) (lib.attrValues secretPolicy.items)
  );

  validateAccessHosts =
    let
      unknownHosts = lib.filter (name: !(config.nstdl.hosts ? ${name})) secretAccessHostNames;
    in
    if unknownHosts == [ ] then
      true
    else
      throw "nstdl secret runtime ACLs reference unknown host(s): ${lib.concatStringsSep ", " unknownHosts}";

  validateHostAccess =
    name: host:
    if
      !hasFeature "secrets" host
      && lib.any (secret: secret.access ? ${host.name}) (lib.attrValues secretPolicy.items)
    then
      throw "nstdl host '${name}' must select the secrets feature before it can receive a runtime secret ACL"
    else
      true;

  validateHost =
    name: host:
    if hasFeature "secrets" host && host.secrets.hostPubkey == null then
      throw "nstdl secrets host '${name}' must set secrets.hostPubkey"
    else if hasFeature "secrets" host && secretPolicy.administrators == { } then
      throw "nstdl secrets host '${name}' requires at least one nstdl.secrets.administrators entry"
    else if hasFeature "secrets" host && administratorKeys == [ ] then
      throw "nstdl secrets administrators require at least one configured key"
    else if
      hasFeature "secrets" host
      && secretPolicy.storage.mode == "local"
      && secretPolicy.storage.root == null
    then
      throw "nstdl secrets host '${name}' requires nstdl.secrets.storage.root when storage.mode is local"
    else if
      hasFeature "secrets" host
      && secretPolicy.storage.mode == "local"
      && builtins.match "^[A-Za-z0-9][A-Za-z0-9._-]*$" host.name == null
    then
      throw "nstdl local secrets host '${name}' must have a path-safe name"
    else if hasFeature "secrets" host && !isRecipient host.secrets.hostPubkey then
      throw "nstdl secrets host '${name}' must use an age or SSH public recipient key"
    else if
      hasFeature "secrets" host
      && lib.any (key: !isRecipient key.publicKey) administratorKeys
    then
      throw "nstdl secrets administrators must use age or SSH public recipient keys"
    else if
      hasFeature "secrets" host
      && lib.any (recipient: !isRecipient recipient) secretPolicy.recoveryRecipients
    then
      throw "nstdl secrets recoveryRecipients must use age or SSH public recipient keys"
    else if
      hasFeature "secrets" host
      && lib.elem (canonicalRecipient host.secrets.hostPubkey) (
        map (key: canonicalRecipient key.publicKey) administratorKeys
      )
    then
      throw "nstdl secrets host '${name}' must not use an administrator public key as its runtime hostPubkey"
    else if
      hasFeature "secrets" host
      && lib.elem (canonicalRecipient host.secrets.hostPubkey) (
        map canonicalRecipient secretPolicy.recoveryRecipients
      )
    then
      throw "nstdl secrets host '${name}' must not use a recovery public key as its runtime hostPubkey"
    else if
      hasFeature "secrets" host
      &&
        lib.count (recipient: recipient == canonicalRecipient host.secrets.hostPubkey) runtimeRecipients
        != 1
    then
      throw "nstdl secrets host '${name}' must use a unique runtime hostPubkey"
    else
      host;

  administratorKeys = lib.concatMap (
    administrator: lib.attrValues administrator.keys
  ) (lib.attrValues secretPolicy.administrators);

  administratorIdentities = map (key: {
    identity = key.identity;
    pubkey = key.publicKey;
  }) administratorKeys;

  moduleFor =
    host:
    if hasFeature "secrets" host then
      { config, ... }:
      let
        runtimeSecrets = lib.filterAttrs (_: secret: secret.access ? ${host.name}) secretPolicy.items;
        secretGroupName = name: "secret-${builtins.substring 0 16 (builtins.hashString "sha256" name)}";
        secretGroupNames = map secretGroupName (lib.attrNames runtimeSecrets);
        duplicateSecretGroupNames = lib.filter (
          group: lib.count (candidate: candidate == group) secretGroupNames > 1
        ) (lib.unique secretGroupNames);
      in
      {
        age.rekey = {
          hostPubkey = host.secrets.hostPubkey;
          masterIdentities = administratorIdentities;
          extraEncryptionPubkeys = secretPolicy.recoveryRecipients;
          storageMode = secretPolicy.storage.mode;
        }
        // lib.optionalAttrs (secretPolicy.storage.mode == "local") {
          localStorageDir = secretPolicy.storage.root + "/${host.name}";
        };
        age.secrets = lib.mapAttrs (
          name: secret:
          let
            access = secret.access.${host.name};
          in
          {
            inherit (secret) rekeyFile;
            mode = access.mode;
          }
          // lib.optionalAttrs (access.owner != null) {
            owner = access.owner;
          }
          // lib.optionalAttrs (access.users != [ ]) {
            group = secretGroupName name;
          }
        ) runtimeSecrets;
        users.groups = lib.mapAttrs' (
          name: secret:
          let
            access = secret.access.${host.name};
          in
          lib.nameValuePair (secretGroupName name) {
            members = lib.mkForce access.users;
          }
        ) (lib.filterAttrs (_: secret: secret.access.${host.name}.users != [ ]) runtimeSecrets);
        assertions = [
          {
            assertion = duplicateSecretGroupNames == [ ];
            message = "nstdl secrets host '${host.name}' has colliding generated secret groups";
          }
          {
            assertion = host.platform == "nixos" || lib.all (secret: secret.access.${host.name}.users == [ ]) (lib.attrValues runtimeSecrets);
            message = "nstdl secrets Darwin host '${host.name}' supports owner and mode ACLs, not Unix group users";
          }
          {
            assertion = config.age.rekey.masterIdentities == administratorIdentities;
            message = "nstdl secrets host '${host.name}' must not add host-local master identities";
          }
          {
            assertion = config.age.rekey.extraEncryptionPubkeys == secretPolicy.recoveryRecipients;
            message = "nstdl secrets host '${host.name}' must not add host-local recovery recipients";
          }
        ];
      }
    else
      { };
in
{
  options.nstdl.secrets = {
    administrators = mkOption {
      type = types.attrsOf (
        types.submodule {
          options.keys = mkOption {
            type = types.attrsOf (
              types.submodule {
                options = {
                  identity = mkOption {
                    type = types.coercedTo types.path toString types.nonEmptyStr;
                    default = "~/.ssh/id_ed25519";
                    description = "Local identity path used by the agenix-rekey command.";
                  };
                  publicKey = mkOption {
                    type = types.nonEmptyStr;
                    description = "Public recipient key for canonical secrets.";
                  };
                };
              }
            );
            default = { };
            description = "Named local keys owned by this administrator.";
          };
        }
      );
      default = { };
      description = "Trusted administrators and the local keys through which they may decrypt and edit canonical secrets.";
    };

    recoveryRecipients = mkOption {
      type = types.listOf types.nonEmptyStr;
      default = [ ];
      description = "Additional public-only break-glass recipients for canonical secrets.";
    };

    items = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            rekeyFile = mkOption {
              type = types.path;
              description = "Canonical encrypted source managed by agenix-rekey.";
            };
            access = mkOption {
              type = types.attrsOf (
                types.submodule {
                  options = {
                    users = mkOption {
                      type = types.listOf types.str;
                      default = [ ];
                      description = "Unix users granted group read access to this secret on the host. nstdl owns that generated group membership.";
                    };
                    owner = mkOption {
                      type = types.nullOr types.str;
                      default = null;
                      description = "Optional owner for the decrypted secret file.";
                    };
                    mode = mkOption {
                      type = types.str;
                      default = "0440";
                      description = "Mode for the decrypted secret file.";
                    };
                  };
                }
              );
              default = { };
              description = "Per-host runtime access policy; it never changes encryption recipients and owns the resulting age.secrets owner, mode, and generated group.";
            };
          };
        }
      );
      default = { };
      description = "Canonical secrets with typed NixOS runtime ACLs.";
    };

    storage = {
      mode = mkOption {
        type = types.enum [
          "local"
          "derivation"
        ];
        default = "local";
        description = "Where agenix-rekey stores host-specific rekeyed files.";
      };
      root = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Consumer repository directory containing local rekeyed host files.";
      };
    };
  };

  config._module.args.nstdlSecrets = {
    inherit
      moduleFor
      validateAccessHosts
      validateHost
      validateHostAccess
      ;
  };
}
