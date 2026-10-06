{ pkgs, module }:

let
  alphaSecret = "alpha-secret-0123456789abcdef";
  betaSecret = "beta-secret-0123456789abcdef";
  rpcSecret = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0";
  adminToken = "admin-token-0123456789abcdef";

  s3 =
    key: secret:
    "AWS_ACCESS_KEY_ID=${key} AWS_SECRET_ACCESS_KEY=${secret} aws --endpoint-url http://127.0.0.1:3900 --region garage";
  alpha = s3 "test-key-alpha" alphaSecret;
  beta = s3 "test-key-beta" betaSecret;

  # Prints the status code; the body goes to /tmp/body.
  web =
    bucket: path:
    "curl -s -o /tmp/body -w '%{http_code}' -H 'Host: ${bucket}' 'http://127.0.0.1:3902${path}'";
  switchTo = name: "/run/booted-system/specialisation/${name}/bin/switch-to-configuration test";
in
pkgs.testers.runNixOSTest {
  name = "nstdl-garage";

  # A Mac's Linux builder has no /dev/kvm; QEMU falls back to TCG, so only the
  # scheduling requirement is dropped. Run it as aarch64-linux there.
  requiredFeatures.kvm = pkgs.lib.mkForce false;

  nodes.machine = {
    imports = [ module ];

    # Test values only; a real host points these at agenix paths.
    environment.etc = {
      "garage-test/rpc-secret" = {
        text = rpcSecret;
        mode = "0400";
      };
      "garage-test/admin-token" = {
        text = adminToken;
        mode = "0400";
      };
      "garage-test/alpha" = {
        text = alphaSecret;
        mode = "0400";
      };
      "garage-test/beta" = {
        text = betaSecret;
        mode = "0400";
      };
    };

    services.nstdl.garage = {
      enable = true;
      rpcSecretFile = "/etc/garage-test/rpc-secret";
      adminTokenFile = "/etc/garage-test/admin-token";
      web.enable = true;
      buckets = {
        alpha.website.enable = true;
        beta.quotas = {
          maxObjects = 1;
          maxSize = 1024;
        };
      };
      keys = {
        test-key-alpha = {
          secretKeyFile = "/etc/garage-test/alpha";
          allow.alpha = [
            "read"
            "write"
            "owner"
          ];
        };
        test-key-beta = {
          secretKeyFile = "/etc/garage-test/beta";
          allow = {
            beta = [
              "read"
              "write"
            ];
            alpha = [ "read" ];
          };
        };
      };
    };

    environment.systemPackages = [
      pkgs.awscli2
      pkgs.curl
      pkgs.jq
    ];

    # Each specialisation changes one declared aspect against the base, so
    # switching to it shows setup applying the change, and switching on from
    # it shows the change being undone.
    specialisation = {
      # Changed documents on a website bucket.
      documents.configuration.services.nstdl.garage.buckets.alpha.website = {
        indexDocument = "object";
        errorDocument = "error.html";
      };

      # Narrows alpha's key to read-only, so switching to it exercises
      # DenyBucketKey against a permission that was actually granted: a
      # no-op Deny would leave the write below succeeding.
      narrowed.configuration.services.nstdl.garage.keys.test-key-alpha.allow.alpha = pkgs.lib.mkForce [
        "read"
      ];

      # Website and quotas removed from the declaration.
      removed.configuration.services.nstdl.garage.buckets = {
        alpha.website.enable = pkgs.lib.mkForce false;
        beta.quotas = {
          maxObjects = pkgs.lib.mkForce null;
          maxSize = pkgs.lib.mkForce null;
        };
      };
    };
  };

  testScript = ''
    machine.wait_for_unit("garage-setup.service")

    # Each key reaches exactly what it was granted.
    machine.succeed("echo hello > /tmp/object")
    machine.succeed("${alpha} s3 cp /tmp/object s3://alpha/object")
    machine.succeed("${beta} s3 cp /tmp/object s3://beta/object")
    machine.succeed("${beta} s3 cp s3://alpha/object - | grep -qx hello")
    machine.fail("${beta} s3 cp /tmp/object s3://alpha/other")
    machine.fail("${alpha} s3 ls s3://beta")

    # beta's object quota is reached: a new object is refused, an overwrite is
    # not. The count the quota is checked against lands asynchronously, so
    # wait until it shows; the token goes into a curl config, not argv.
    machine.succeed("""printf 'header = "Authorization: Bearer %s"\n' "$(cat /etc/garage-test/admin-token)" > /tmp/admin-curlrc""")
    machine.wait_until_succeeds("curl -sf -K /tmp/admin-curlrc 'http://127.0.0.1:3903/v2/GetBucketInfo?globalAlias=beta' | jq -e '.objects == 1'")
    machine.fail("${beta} s3 cp /tmp/object s3://beta/other")
    machine.succeed("${beta} s3 cp /tmp/object s3://beta/object")

    # The size quota refuses what would exceed it, even as an overwrite.
    machine.succeed("head -c 2048 /dev/zero > /tmp/large")
    machine.fail("${beta} s3 cp /tmp/large s3://beta/object")

    # The web endpoint serves objects of a website bucket only. Without an
    # index document `/` is a 404, and a listing query is just `/`: Garage
    # never lists over it.
    machine.wait_for_open_port(3902)
    machine.succeed("echo oops > /tmp/error.html")
    machine.succeed("${alpha} s3 cp /tmp/error.html s3://alpha/error.html")
    machine.succeed("[ $(${web "alpha" "/object"}) = 200 ] && grep -qx hello /tmp/body")
    machine.succeed("[ $(${web "alpha" "/"}) = 404 ]")
    machine.succeed("[ $(${web "alpha" "/?list-type=2"}) = 404 ] && ! grep -q -e ListBucketResult -e '<Key>' /tmp/body")
    machine.succeed("[ $(${web "beta" "/object"}) = 404 ] && ! grep -q hello /tmp/body")

    # Idempotent: a rerun changes nothing and succeeds.
    machine.succeed("systemctl restart garage-setup.service")
    machine.succeed("${alpha} s3 cp s3://alpha/object - | grep -qx hello")
    machine.succeed("[ $(${web "alpha" "/object"}) = 200 ]")

    # Changed documents are applied.
    machine.succeed("${switchTo "documents"}")
    machine.wait_for_unit("garage-setup.service")
    machine.succeed("[ $(${web "alpha" "/"}) = 200 ] && grep -qx hello /tmp/body")
    machine.succeed("[ $(${web "alpha" "/missing"}) = 404 ] && grep -qx oops /tmp/body")

    # A previously granted permission is actually removed: alpha's key loses
    # write on the "narrowed" specialisation, so this DenyBucketKey call is
    # not a no-op.
    machine.succeed("${switchTo "narrowed"}")
    machine.wait_for_unit("garage-setup.service")
    machine.succeed("${alpha} s3 cp s3://alpha/object - | grep -qx hello")
    machine.fail("${alpha} s3 cp /tmp/object s3://alpha/object")

    # Back on the base documents there: the error document is cleared, not
    # kept, and `/` looks for index.html again.
    machine.succeed("[ $(${web "alpha" "/missing"}) = 404 ] && ! grep -q oops /tmp/body")
    machine.succeed("[ $(${web "alpha" "/"}) = 404 ]")

    # A website dropped from the declaration is disabled; the bucket stays.
    # Dropped quotas are cleared: both writes refused above now succeed.
    machine.succeed("${switchTo "removed"}")
    machine.wait_for_unit("garage-setup.service")
    machine.succeed("[ $(${web "alpha" "/object"}) = 404 ] && ! grep -q hello /tmp/body")
    machine.succeed("${alpha} s3 cp s3://alpha/object - | grep -qx hello")
    machine.succeed("${beta} s3 cp /tmp/object s3://beta/other")
    machine.succeed("${beta} s3 cp /tmp/large s3://beta/object")

    # A changed secret for an existing key ID fails loudly instead of diverging.
    machine.succeed("echo -n changed-secret-0123456789 > /etc/garage-test/alpha")
    machine.fail("systemctl restart garage-setup.service")
    machine.succeed("journalctl -u garage-setup.service | grep -q 'exists with a different secret'")

    # No secret in any process environment or command line, nor in the journal.
    # The pattern comes from a file (printf is a shell builtin): as an argument,
    # grep would find it in its own command line.
    for secret in ["${alphaSecret}", "${betaSecret}", "${rpcSecret}", "${adminToken}"]:
        machine.succeed(f"printf %s {secret} > /tmp/pattern")
        machine.fail("grep -qaF -f /tmp/pattern /proc/[0-9]*/environ /proc/[0-9]*/cmdline")
        machine.fail("journalctl | grep -qF -f /tmp/pattern")
  '';
}
