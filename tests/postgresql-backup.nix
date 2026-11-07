{ pkgs, module }:

let
  declaredPassword = "declared-password-0123456789";
  psql = "sudo -u postgres psql -X -At";
  sets = "/var/lib/nstdl-postgresql-backup";
in
pkgs.testers.runNixOSTest {
  name = "nstdl-postgresql-backup";

  # A Mac's Linux builder has no /dev/kvm; QEMU falls back to TCG, so only the
  # scheduling requirement is dropped. Run it as aarch64-linux there.
  requiredFeatures.kvm = pkgs.lib.mkForce false;

  nodes.machine = {
    imports = [ module ];

    # Test value only; a real host points this at an agenix path.
    environment.etc."postgresql-test/app" = {
      text = declaredPassword;
      mode = "0400";
    };

    services.nstdl.postgresql = {
      enable = true;
      roles.app = {
        enable = true;
        passwordFile = "/etc/postgresql-test/app";
      };
      databases = {
        app.owner = "app";
        app_staging = { };
      };
      backup = {
        enable = true;
        exclude = [ "app_staging" ];
        calendar = null;
      };
    };
  };

  testScript = ''
    machine.wait_for_unit("nstdl-postgresql-reconcile.service")

    def sql(statement, database="postgres"):
        return machine.succeed(f"${psql} -d {database} -c \"{statement}\"").strip()

    # A cluster with everything a restore must bring back: an undeclared role
    # and database, grants, a database setting, and a password that differs
    # from the declared one.
    sql("CREATE ROLE analyst LOGIN PASSWORD 'analyst-password'")
    sql("ALTER ROLE app PASSWORD 'backed-up-password'")
    sql("ALTER DATABASE app SET work_mem = '7MB'")
    sql("CREATE TABLE items (id int PRIMARY KEY, name text)", "app")
    sql("INSERT INTO items VALUES (1, 'one'), (2, 'two')", "app")
    sql("GRANT SELECT ON items TO analyst", "app")
    sql("CREATE DATABASE scratch OWNER analyst")
    sql("CREATE TABLE notes (body text)", "scratch")
    sql("INSERT INTO notes VALUES ('kept')", "scratch")

    with subtest("a backup set holds every database but the excluded one, and the roles"):
        machine.succeed("systemctl start nstdl-postgresql-backup.service")
        machine.succeed("[ $(stat -c %U:%a ${sets}) = postgres:700 ]")
        backup_set = "${sets}/" + machine.succeed("ls ${sets}").strip()
        files = machine.succeed(f"ls {backup_set}").split()
        assert files == ["app.dump", "globals.sql", "postgres.dump", "scratch.dump", "template1.dump"], files
        machine.succeed("journalctl -u nstdl-postgresql-backup.service | grep -q 'wrote ${sets}/'")

    with subtest("the host's nstdl lists the restore command and points elsewhere for repository commands"):
        machine.succeed("nstdl | grep -q 'postgresql restore'")
        machine.fail("nstdl deploy")
        machine.succeed("{ nstdl deploy || true; } 2>&1 | grep -q './nstdl'")
        machine.fail(f"sudo -u nobody nstdl postgresql restore {backup_set}")
        machine.succeed(f"{{ sudo -u nobody nstdl postgresql restore {backup_set} || true; }} 2>&1 | grep -q 'run it as root'")

    with subtest("a rebuilt host gets everything back"):
        # Lose the cluster; the host recreates its declared roles and empty
        # databases, as after a reinstall.
        machine.succeed("systemctl stop postgresql.service")
        machine.succeed("rm -rf /var/lib/postgresql/*")
        machine.succeed("systemctl start postgresql.service")
        machine.succeed("systemctl restart postgresql-setup.service")
        machine.succeed("systemctl restart nstdl-postgresql-reconcile.service")
        assert sql("SELECT count(*) FROM pg_roles WHERE rolname = 'analyst'") == "0"

        # Only empty, declared databases stand in the way: no confirmation.
        machine.succeed(f"nstdl postgresql restore {backup_set}")
        assert sql("SELECT string_agg(name, ',' ORDER BY id) FROM items", "app") == "one,two"
        assert sql("SELECT body FROM notes", "scratch") == "kept"
        assert sql("SHOW work_mem", "app") == "7MB"
        assert sql("SELECT has_table_privilege('analyst', 'items', 'SELECT')", "app") == "t"
        assert sql("SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'app'") == "app"
        machine.succeed("PGPASSWORD=analyst-password psql -X -h 127.0.0.1 -U analyst -d scratch -c 'SELECT 1'")
        # The declared password wins over the backed-up one.
        machine.succeed("PGPASSWORD=${declaredPassword} psql -X -h 127.0.0.1 -U app -d app -c 'SELECT 1'")
        machine.fail("PGPASSWORD=backed-up-password psql -X -h 127.0.0.1 -U app -d app -c 'SELECT 1'")

    with subtest("replacing databases that hold data needs confirmation"):
        sql("INSERT INTO items VALUES (3, 'three')", "app")
        # The driver's shell is on a console, so stdin would be a terminal.
        output = machine.fail(f"nstdl postgresql restore {backup_set} </dev/null 2>&1")
        assert "--yes" in output and "app" in output, output
        assert sql("SELECT count(*) FROM items", "app") == "3"
        machine.succeed(f"nstdl postgresql restore {backup_set} --yes")
        assert sql("SELECT count(*) FROM items", "app") == "2"

    with subtest("the declared password appears in no process or log"):
        # The pattern comes from a file (printf is a shell builtin): as an
        # argument, grep would find it in its own command line.
        machine.succeed("printf %s ${declaredPassword} > /tmp/pattern")
        machine.fail("grep -qaF -f /tmp/pattern /proc/[0-9]*/environ /proc/[0-9]*/cmdline")
        machine.fail("journalctl | grep -qF -f /tmp/pattern")
  '';
}
