{
  config,
  lib,
  self,
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

  # Byte formats encode random bytes for keys and tokens and are sized in
  # `bytes` (at least 16, 128 bits). Character formats are for typed passwords,
  # which are only attackable through a slow yescrypt hash, and are sized in
  # `length`: at least 80 bits.
  randomFormats = {
    hex.sizing = "bytes";
    base64.sizing = "bytes";
    base64url.sizing = "bytes";
    alphanumeric = {
      sizing = "length";
      minimumLength = 14;
    };
    alphanumeric-lowercase = {
      sizing = "length";
      minimumLength = 16;
    };
  };

  validateItems =
    let
      problems = lib.concatLists (
        lib.mapAttrsToList (
          name: item:
          let
            generator = item.generator;
            from = if generator == null then null else generator.from;
            source = if from == null then null else secretPolicy.items.${from} or null;
          in
          lib.optional (from != null && generator.type != "password-hash")
            "nstdl secret '${name}': generator.from is only valid for type password-hash"
          ++ lib.optional (from != null && source == null)
            "nstdl secret '${name}': generator.from references unknown secret '${from}'"
          ++ lib.optional (
            source != null && source.generator != null && source.generator.type == "password-hash"
          ) "nstdl secret '${name}': generator.from must name a plaintext secret, not the hash '${from}'"
          ++ lib.optional (from != null && item.rotate)
            "nstdl secret '${name}': a derived secret cannot set rotate; it follows its source '${from}'"
          ++ lib.optional (
            generator != null
            && generator.type == "random"
            && randomFormats.${generator.format}.sizing == "bytes"
            && generator.length != null
          ) "nstdl secret '${name}': ${generator.format} is sized with generator.bytes, not length"
          ++ lib.optional (
            generator != null
            && generator.type == "random"
            && randomFormats.${generator.format}.sizing == "length"
            && generator.bytes != null
          ) "nstdl secret '${name}': ${generator.format} is sized with generator.length, not bytes"
          ++ lib.optional (
            generator != null
            && generator.type == "random"
            && generator.length != null
            && generator.length < randomFormats.${generator.format}.minimumLength or 0
          ) "nstdl secret '${name}': a ${generator.format} length below ${
            toString randomFormats.${generator.format}.minimumLength
          } is weaker than 80 bits"
        ) secretPolicy.items
      );
    in
    if problems == [ ] then true else throw (lib.concatStringsSep "\n" problems);

  # Canonical files are addressed relative to the consumer flake, which is also
  # where the CLI runs. Context is dropped: the manifest records locations, it
  # must not pull the consumer's source into its closure.
  flakeRelative =
    what: path:
    let
      root = toString self + "/";
      absolute = toString path;
    in
    if lib.hasPrefix root absolute then
      builtins.unsafeDiscardStringContext (lib.removePrefix root absolute)
    else
      throw "nstdl secrets: ${what} (${absolute}) must lie inside the consuming flake";

  # Everything `nstdl secret` needs, fixed at evaluation time so the command
  # follows the consumer's lock and never evaluates a host system itself.
  manifest = builtins.seq validateItems {
    recipients = lib.unique (
      map canonicalRecipient (map (key: key.publicKey) administratorKeys ++ secretPolicy.recoveryRecipients)
    );
    identities = lib.unique (map (key: key.identity) administratorKeys);
    items = lib.mapAttrs (name: item: {
      file = flakeRelative "secret '${name}' rekeyFile" item.rekeyFile;
      inherit (item) rotate;
      generator =
        if item.generator == null then
          null
        else
          {
            inherit (item.generator)
              type
              format
              words
              from
              ;
            bytes =
              if randomFormats.${item.generator.format}.sizing == "bytes" then
                lib.defaultTo 32 item.generator.bytes
              else
                null;
            length =
              if randomFormats.${item.generator.format}.sizing == "length" then
                lib.defaultTo 20 item.generator.length
              else
                null;
          };
      # Mirrors agenix-rekey's local storage naming so `status` can tell a
      # missing rekey without evaluating hosts (checked by tests/evaluate.sh).
      hosts = lib.mapAttrsToList (hostName: _: {
        name = hostName;
        pubkey = config.nstdl.hosts.${hostName}.secrets.hostPubkey;
        rekeyedDir =
          if secretPolicy.storage.mode == "local" then
            flakeRelative "nstdl.secrets.storage.root" secretPolicy.storage.root + "/${hostName}"
          else
            null;
      }) item.access;
    }) secretPolicy.items;
  };

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
            generator = mkOption {
              type = types.nullOr (
                types.submodule {
                  options = {
                    type = mkOption {
                      type = types.enum [
                        "random"
                        "passphrase"
                        "password-hash"
                      ];
                      description = "`random`: random bytes; `passphrase`: random words; `password-hash`: a yescrypt crypt hash.";
                    };
                    format = mkOption {
                      type = types.enum (lib.attrNames randomFormats);
                      default = "hex";
                      description = "random: `hex`, `base64` and `base64url` encode random bytes; `alphanumeric` (a-zA-Z0-9) and `alphanumeric-lowercase` (a-z0-9) pick characters.";
                    };
                    bytes = mkOption {
                      type = types.nullOr (types.ints.between 16 1024);
                      default = null;
                      description = "random, byte formats only: number of random bytes the value decodes to. Default 32.";
                    };
                    length = mkOption {
                      type = types.nullOr (types.ints.between 1 4096);
                      default = null;
                      description = "random, character formats only: number of characters, each drawn uniformly; at least 80 bits (alphanumeric 14, alphanumeric-lowercase 16). Default 20.";
                    };
                    words = mkOption {
                      type = types.ints.between 4 16;
                      default = 6;
                      description = ''
                        passphrase: number of words drawn from the EFF long list, unfiltered by length and restricted to ASCII (7772 of 7776 words, 12.9 bits each), lowercase and space-separated so the value types identically on any keyboard layout.

                        The default 6 is chosen here rather than inherited from xkcdpass: ~77.5 bits, EFF's stated minimum for this list, and the lowest count that stays out of reach even assuming yescrypt were broken down to a fast primitive. A consumer should not need to set this.

                        Each further word adds 12.9 bits and ~8 characters to type. The floor of 4 (51.7 bits) leans on the hash holding up; it exists for non-password uses, not as a suggestion.
                      '';
                    };
                    from = mkOption {
                      type = types.nullOr types.str;
                      default = null;
                      description = "password-hash: the secret whose value is hashed. Null means `nstdl secret set` prompts for the password.";
                    };
                  };
                }
              );
              default = null;
              description = "How `nstdl secret` creates the value. Null: an externally issued value, provided with `nstdl secret set`.";
            };
            rotate = mkOption {
              type = types.bool;
              default = false;
              description = "Whether an existing value may ever be replaced (`rotate`, `edit`). Keep false for values whose change breaks existing data, such as encryption keys.";
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
      manifest
      moduleFor
      validateAccessHosts
      validateHost
      validateHostAccess
      ;
  };
}
