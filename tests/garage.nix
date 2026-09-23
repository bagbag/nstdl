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
      buckets = {
        alpha = { };
        beta = { };
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

    environment.systemPackages = [ pkgs.awscli2 ];

    # Narrows alpha's key to read-only, so switching to it exercises
    # DenyBucketKey against a permission that was actually granted: a
    # no-op Deny would leave the write below succeeding.
    specialisation.narrowed.configuration = {
      services.nstdl.garage.keys.test-key-alpha.allow.alpha = pkgs.lib.mkForce [ "read" ];
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

    # Idempotent: a rerun changes nothing and succeeds.
    machine.succeed("systemctl restart garage-setup.service")
    machine.succeed("${alpha} s3 cp s3://alpha/object - | grep -qx hello")

    # A previously granted permission is actually removed: alpha's key loses
    # write on the "narrowed" specialisation, so this DenyBucketKey call is
    # not a no-op.
    machine.succeed("/run/current-system/specialisation/narrowed/bin/switch-to-configuration test")
    machine.wait_for_unit("garage-setup.service")
    machine.succeed("${alpha} s3 cp s3://alpha/object - | grep -qx hello")
    machine.fail("${alpha} s3 cp /tmp/object s3://alpha/object")

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
