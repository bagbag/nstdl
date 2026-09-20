{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.nstdl.garage;

  adminApi = "http://127.0.0.1:3903";

  permissions = [
    "read"
    "write"
    "owner"
  ];

  # Garage 2.x accepts imported key IDs of at least 8 characters from this set
  # (`Key::import`); S3 bucket names are 3–63 lowercase characters.
  validKeyId = id: builtins.match "[A-Za-z0-9._-]{8,}" id != null;
  validBucket = name: builtins.match "[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]" name != null;

  credential = id: "key-${id}";

  bucketScript = name: ''
    if ! get "/v2/GetBucketInfo?globalAlias=${name}"; then
      jq -n --arg alias ${lib.escapeShellArg name} '{globalAlias: $alias}' | post /v2/CreateBucket
    fi
  '';

  keyScript =
    id: key:
    let
      secret = ''"$CREDENTIALS_DIRECTORY"/${lib.escapeShellArg (credential id)}'';
      grant =
        bucket:
        let
          granted = key.allow.${bucket} or [ ];
          flags = value: lib.genAttrs permissions (permission: lib.elem permission granted == value);
        in
        ''
          get "/v2/GetBucketInfo?globalAlias=${bucket}"
          bucket_id=$(jq -r .id "$response")
          change_permissions AllowBucketKey "$bucket_id" ${lib.escapeShellArg id} ${lib.escapeShellArg (builtins.toJSON (flags true))}
          change_permissions DenyBucketKey "$bucket_id" ${lib.escapeShellArg id} ${lib.escapeShellArg (builtins.toJSON (flags false))}
        '';
    in
    ''
      if get "/v2/GetKeyInfo?id=${id}&showSecretKey=true"; then
        if [ "$(jq -r --rawfile secret ${secret} '.secretAccessKey == ($secret | rtrimstr("\n"))' "$response")" != true ]; then
          echo "Garage key '${id}' exists with a different secret. Garage never forgets a key ID (a deleted key stays" \
            "as a tombstone and blocks re-import), so a new secret needs a new key ID." >&2
          exit 1
        fi
      else
        jq -n --arg id ${lib.escapeShellArg id} --rawfile secret ${secret} \
          '{accessKeyId: $id, name: $id, secretAccessKey: ($secret | rtrimstr("\n"))}' | post /v2/ImportKey
      fi
    ''
    + lib.concatMapStrings grant (lib.attrNames cfg.buckets);
in
{
  imports = [ ./systemd-sandbox.nix ];

  options.services.nstdl.garage = {
    enable = lib.mkEnableOption ''
      single-node Garage object storage, listening on loopback only: S3 on
      127.0.0.1:3900, RPC on 3901, admin API on 3903.

      Buckets and keys are declared here and applied by `garage-setup.service`,
      which services using them should require. It creates and grants, and
      never deletes: undeclared buckets and keys are left as they are'';

    package = lib.mkPackageOption pkgs "garage_2" { };

    rpcSecretFile = lib.mkOption {
      type = lib.types.str;
      description = "File holding the RPC secret: 32 random bytes, hex-encoded. Read through systemd credentials.";
    };

    adminTokenFile = lib.mkOption {
      type = lib.types.str;
      description = "File holding the admin API bearer token. Read through systemd credentials.";
    };

    region = lib.mkOption {
      type = lib.types.str;
      default = "garage";
      description = "S3 region name clients must use.";
    };

    buckets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule { });
      default = { };
      description = "Buckets to create, by global alias.";
    };

    keys = lib.mkOption {
      default = { };
      description = ''
        Access keys to import, by key ID. A key's secret is fixed once imported:
        Garage cannot re-import a key ID, even after deleting it, so replacing a
        secret means declaring a new key ID.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            secretKeyFile = lib.mkOption {
              type = lib.types.str;
              description = "File holding the secret key: at least 16 printable ASCII characters.";
            };
            allow = lib.mkOption {
              type = lib.types.attrsOf (lib.types.listOf (lib.types.enum permissions));
              default = { };
              example = {
                media = [
                  "read"
                  "write"
                ];
              };
              description = ''
                Permissions per declared bucket. Applied exactly: a permission
                not listed is revoked, on every declared bucket.
              '';
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all validKeyId (lib.attrNames cfg.keys);
        message = "services.nstdl.garage.keys: key IDs need at least 8 characters from [A-Za-z0-9._-].";
      }
      {
        assertion = lib.all validBucket (lib.attrNames cfg.buckets);
        message = "services.nstdl.garage.buckets: names need 3–63 characters from [a-z0-9.-], starting and ending alphanumerically.";
      }
      {
        assertion = lib.all (key: lib.all (bucket: cfg.buckets ? ${bucket}) (lib.attrNames key.allow)) (
          lib.attrValues cfg.keys
        );
        message = "services.nstdl.garage.keys.<id>.allow may only name buckets declared in services.nstdl.garage.buckets.";
      }
    ];

    services.garage = {
      enable = true;
      inherit (cfg) package;
      settings = {
        replication_factor = 1;
        rpc_bind_addr = "127.0.0.1:3901";
        rpc_public_addr = "127.0.0.1:3901";
        rpc_secret_file = "/run/credentials/garage.service/rpc-secret";
        # systemd hands a DynamicUser its credentials as 0440 (the unit's own
        # group), which Garage's 0600 check rejects. The credentials directory
        # is private to the unit, so nothing else can read them either way.
        allow_world_readable_secrets = true;
        s3_api = {
          s3_region = cfg.region;
          api_bind_addr = "127.0.0.1:3900";
        };
        admin = {
          api_bind_addr = "127.0.0.1:3903";
          admin_token_file = "/run/credentials/garage.service/admin-token";
        };
      };
    };

    systemd.services.garage.serviceConfig = {
      # Assigns the one-node layout on first start (zone and capacity only
      # weigh nodes against each other), and refuses to start once the layout
      # has moved past version 1 — growing beyond one node means dropping it.
      ExecStart = lib.mkForce "${lib.getExe cfg.package} server --single-node";
      LoadCredential = [
        "rpc-secret:${cfg.rpcSecretFile}"
        "admin-token:${cfg.adminTokenFile}"
      ];
    };

    systemd.services.garage-setup = {
      description = "Garage buckets and keys";
      after = [ "garage.service" ];
      requires = [ "garage.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.curl
        pkgs.jq
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        DynamicUser = true;
        RuntimeDirectory = "garage-setup";
        LoadCredential = [
          "admin-token:${cfg.adminTokenFile}"
        ]
        ++ lib.mapAttrsToList (id: key: "${credential id}:${key.secretKeyFile}") cfg.keys;
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
        TimeoutStartSec = "5min";
      };
      # Secrets reach curl and jq only through files: the bearer token in a
      # curl config, bodies on stdin. Nothing secret is in argv or the
      # environment, and the runtime directory is emptied on exit.
      script = ''
        set -euo pipefail
        curlrc="$RUNTIME_DIRECTORY/curlrc"
        response="$RUNTIME_DIRECTORY/response"
        trap 'rm -f "$curlrc" "$response"' EXIT
        printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\n' < "$CREDENTIALS_DIRECTORY/admin-token")" > "$curlrc"

        # Leaves the body in $response; fails on anything but 2xx or 404.
        get() {
          local status
          status=$(curl -sS -K "$curlrc" -o "$response" -w '%{http_code}' "${adminApi}$1")
          case "$status" in
            2??) return 0 ;;
            404) return 1 ;;
            *) echo "GET $1: HTTP $status: $(cat "$response")" >&2; exit 1 ;;
          esac
        }
        post() {
          local status
          status=$(curl -sS -K "$curlrc" -o "$response" -w '%{http_code}' \
            -H 'Content-Type: application/json' --data-binary @- "${adminApi}$1")
          case "$status" in
            2??) ;;
            *) echo "POST $1: HTTP $status: $(cat "$response")" >&2; exit 1 ;;
          esac
        }

        # ENDPOINT BUCKET_ID KEY_ID FLAGS: sets (Allow) or clears (Deny) the flags that are true.
        change_permissions() {
          jq -n --arg bucket "$2" --arg key "$3" --argjson flags "$4" \
            '{bucketId: $bucket, accessKeyId: $key, permissions: $flags}' | post "/v2/$1"
        }

        until curl -sf -o /dev/null "${adminApi}/health"; do sleep 1; done
      ''
      + lib.concatMapStrings bucketScript (lib.attrNames cfg.buckets)
      + lib.concatStrings (lib.mapAttrsToList keyScript cfg.keys);
    };

    services.nstdl.systemd.services.garage-setup.sandbox = {
      enable = true;
      extend.RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
    };
  };
}
