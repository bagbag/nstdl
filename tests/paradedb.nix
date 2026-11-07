{ pkgs, modules }:

let
  psql = "sudo -u postgres psql -X -At";
in
pkgs.testers.runNixOSTest {
  name = "nstdl-paradedb";

  # A Mac's Linux builder has no /dev/kvm; QEMU falls back to TCG, so only the
  # scheduling requirement is dropped. Run it as aarch64-linux there.
  requiredFeatures.kvm = pkgs.lib.mkForce false;

  nodes.machine = {
    imports = modules;

    services.nstdl.paradedb.enable = true;
    services.nstdl.postgresql = {
      enable = true;
      databases.app.extensions = [ "pg_search" ];
    };
  };

  testScript = ''
    def sql(statement, database="app"):
        return machine.succeed(f"${psql} -d {database} -c \"{statement}\"").strip()

    def extension_version(name, database="app"):
        return sql(f"SELECT extversion FROM pg_extension WHERE extname = '{name}'", database)

    def available_version(name):
        return sql(f"SELECT default_version FROM pg_available_extensions WHERE name = '{name}'")

    # Preloaded: postgres only starts if the library's RUNPATH resolves.
    machine.wait_for_unit("postgresql-setup.service")
    # Creates pg_search in `app`; a oneshot that does not stay active.
    machine.succeed("systemctl restart nstdl-postgresql-reconcile.service")

    with subtest("the declared extension's catalog matches the loaded binary"):
        version = extension_version("pg_search")
        assert version == sql("SELECT version FROM paradedb.version_info()"), version
        assert version == available_version("pg_search"), version

    with subtest("a search index answers queries"):
        sql("CREATE TABLE items (id int PRIMARY KEY, body text)")
        sql("INSERT INTO items VALUES (1, 'the quick brown fox'), (2, 'a lazy dog'), (3, 'quick thinking')")
        sql("CREATE INDEX items_search ON items USING paradedb (id, body)")
        result = sql("SELECT id FROM items WHERE body @@@ 'quick' ORDER BY id")
        assert result.split() == ["1", "3"], result

    # hstore ships several versions, so it can stand in for a package bump.
    def assert_updated_after(action):
        sql("DROP EXTENSION IF EXISTS hstore")
        sql("CREATE EXTENSION hstore VERSION '1.4'")
        machine.succeed(action)
        machine.wait_for_unit("postgresql-setup.service")
        machine.wait_until_succeeds(
            f"test \"$(${psql} -d app -c \"SELECT extversion FROM pg_extension WHERE extname = 'hstore'\")\" = '{available_version('hstore')}'",
            timeout=60,
        )

    with subtest("a server restart updates lagging extensions"):
        assert_updated_after("systemctl restart postgresql.service")

    with subtest("a server stop and start updates lagging extensions"):
        assert_updated_after("systemctl stop postgresql.service && systemctl start postgresql.service")
  '';
}
