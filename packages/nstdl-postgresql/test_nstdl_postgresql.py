"""Tests for nstdl-postgresql: retention and naming as pure functions, backup and
restore against a throwaway PostgreSQL server on a Unix socket."""

import io
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).parent))
import nstdl_postgresql as tool  # noqa: E402

KEEP = {"daily": 7, "weekly": 4, "monthly": 6}


class RetentionTest(unittest.TestCase):
    def test_daily_backups_over_a_year_keep_days_weeks_and_months(self):
        start = datetime(2026, 1, 1, 3, tzinfo=timezone.utc)
        times = [start + timedelta(days=day) for day in range(365)]
        result = sorted(tool.kept(times, KEEP), reverse=True)
        newest = times[-1]
        self.assertEqual(result[:7], [newest - timedelta(days=day) for day in range(7)])
        # 7 days, then week and month ends not already kept.
        self.assertTrue(10 <= len(result) <= 17, len(result))
        self.assertEqual(len({time.isocalendar()[:2] for time in result if time > newest - timedelta(weeks=5)}), 5)
        self.assertEqual(len({(time.year, time.month) for time in result}), 6)

    def test_newest_set_of_each_bucket_is_kept(self):
        morning = datetime(2026, 3, 2, 1, tzinfo=timezone.utc)
        evening = morning + timedelta(hours=20)
        self.assertEqual(tool.kept([morning, evening], {"daily": 1, "weekly": 0, "monthly": 0}), {evening})

    def test_newest_set_survives_zero_counts(self):
        time = datetime(2026, 3, 2, tzinfo=timezone.utc)
        self.assertEqual(tool.kept([time], {"daily": 0, "weekly": 0, "monthly": 0}), {time})

    def test_prune_touches_only_backup_sets(self):
        with tempfile.TemporaryDirectory() as directory:
            location = Path(directory)
            for name in ("2026-01-01T030000Z", "2026-01-02T030000Z", "unrelated", "2026-01-03"):
                (location / name).mkdir()
            tool.prune(location, {"daily": 1, "weekly": 0, "monthly": 0})
            self.assertEqual(sorted(path.name for path in location.iterdir()), ["2026-01-02T030000Z", "2026-01-03", "unrelated"])


class NamingTest(unittest.TestCase):
    def test_dump_file_names_are_reversible_and_flat(self):
        self.assertEqual(tool.dump_file_name("app"), "app.dump")
        self.assertEqual(tool.dump_file_name("a/b%c"), "a%2Fb%25c.dump")
        self.assertEqual(tool.dump_file_name(".hidden"), "%2Ehidden.dump")
        self.assertEqual(tool.dump_file_name("my app"), "my app.dump")

    def test_identifiers_are_quoted(self):
        self.assertEqual(tool.quote_identifier('we"ird'), '"we""ird"')


class PasswordTest(unittest.TestCase):
    def test_verifier_has_pg_authid_format(self):
        verifier = tool.scram_verifier(b"secret", salt=b"0123456789abcdef")
        self.assertRegex(verifier, r"^SCRAM-SHA-256\$4096:MDEyMzQ1Njc4OWFiY2RlZg==\$[A-Za-z0-9+/]{43}=:[A-Za-z0-9+/]{43}=$")
        self.assertNotEqual(tool.scram_verifier(b"secret"), tool.scram_verifier(b"secret"))

    def test_saslprep(self):
        self.assertEqual(tool.saslprep("plain ascii"), b"plain ascii")
        # Non-ASCII space maps to a space, soft hyphen to nothing, NFKC folds.
        self.assertEqual(tool.saslprep("a\u00a0b\u00adc\u2163"), b"a bcIV")
        # Prohibited characters leave the password unchanged, like PostgreSQL.
        self.assertEqual(tool.saslprep("\u00e4\u0007"), "\u00e4\u0007".encode())


class ConfirmTest(unittest.TestCase):
    def test_nothing_to_replace_asks_nothing(self):
        with mock.patch("builtins.input") as prompt:
            tool.confirm([], assume_yes=False)
        prompt.assert_not_called()

    def test_without_terminal_refuses_unless_yes(self):
        with mock.patch("sys.stdin.isatty", return_value=False):
            with self.assertRaisesRegex(tool.Failure, "--yes"):
                tool.confirm(["app"], assume_yes=False)
            tool.confirm(["app"], assume_yes=True)

    def test_each_name_must_be_typed(self):
        with mock.patch("sys.stdin.isatty", return_value=True):
            with mock.patch("builtins.input", side_effect=["app", "other"]) as prompt:
                tool.confirm(["app", "other"], assume_yes=False)
            self.assertEqual(prompt.call_count, 2)
            with mock.patch("builtins.input", side_effect=["app", "y"]):
                with self.assertRaisesRegex(tool.Failure, "not confirmed"):
                    tool.confirm(["app", "other"], assume_yes=False)


class ServerTest(unittest.TestCase):
    """Backup and restore against a real server, run as the current user."""

    @classmethod
    def setUpClass(cls):
        # Short: macOS limits Unix socket paths to 104 bytes.
        cls.directory = tempfile.mkdtemp(prefix="pg")
        cls.data = Path(cls.directory) / "data"
        subprocess.run(["initdb", "-D", str(cls.data), "-U", "postgres", "--auth=trust", "--no-sync"], check=True, capture_output=True)
        # The login role proves set-password's verifier; everyone else is trusted.
        (cls.data / "pg_hba.conf").write_text("local all login scram-sha-256\nlocal all all trust\n")
        # Test extensions go to <extensions>/extension, searched first. pg_ctl
        # starts the server through a shell, hence the escaped `$system`.
        cls.extensions = Path(cls.directory) / "extensions"
        (cls.extensions / "extension").mkdir(parents=True)
        subprocess.run(["pg_ctl", "-D", str(cls.data), "-w", "-l", str(Path(cls.directory) / "log"), "-o", f"-k {cls.directory} -c listen_addresses= -c fsync=off -c extension_control_path={cls.extensions}:\\$system", "start"], check=True, capture_output=True)
        cls.environment = mock.patch.dict(os.environ, {"PGHOST": cls.directory, "PGUSER": "postgres"})
        cls.environment.start()

    @classmethod
    def tearDownClass(cls):
        cls.environment.stop()
        subprocess.run(["pg_ctl", "-D", str(cls.data), "-m", "immediate", "stop"], capture_output=True)
        subprocess.run(["rm", "-rf", cls.directory])

    def sql(self, statement, database="postgres"):
        return tool.query(statement, database)

    def setUp(self):
        for name in self.sql("SELECT datname FROM pg_database WHERE datname NOT IN ('postgres', 'template0', 'template1')"):
            self.sql(f"DROP DATABASE {tool.quote_identifier(name)} WITH (FORCE)")
        for role in ("app", "reporting", "login"):
            self.sql(f"DROP ROLE IF EXISTS {role}")
        for database in ("postgres", "template1"):
            self.sql("DROP EXTENSION IF EXISTS hstore", database)
        self.sql("DROP EXTENSION IF EXISTS rollback_probe")
        self.location = Path(tempfile.mkdtemp())

    def tearDown(self):
        subprocess.run(["rm", "-rf", str(self.location)])

    def create_cluster(self):
        self.sql("CREATE ROLE app LOGIN PASSWORD 'secret'")
        self.sql("CREATE ROLE reporting")
        self.sql("CREATE DATABASE app OWNER app")
        self.sql("ALTER DATABASE app SET work_mem = '7MB'")
        self.sql("REVOKE CONNECT ON DATABASE app FROM PUBLIC")
        self.sql("GRANT CONNECT ON DATABASE app TO reporting")
        self.sql("CREATE TABLE items (id int PRIMARY KEY, name text)", "app")
        self.sql("INSERT INTO items VALUES (1, 'one'), (2, 'two')", "app")
        self.sql("GRANT SELECT ON items TO reporting", "app")
        self.sql("CREATE DATABASE staging")
        self.sql('CREATE DATABASE "odd/name"')

    def test_backup_restores_roles_settings_grants_and_data(self):
        self.create_cluster()
        backup_set = tool.backup(self.location, ["staging", "missing"], KEEP)
        files = sorted(path.name for path in backup_set.iterdir())
        self.assertEqual(files, ["app.dump", "globals.sql", "odd%2Fname.dump", "postgres.dump", "template1.dump"])
        self.assertFalse(list(self.location.glob(".in-progress-*")))

        # Lose everything, then rebuild the way a fresh host would: the
        # declared database exists empty.
        for name in ("app", "staging", "odd/name"):
            self.sql(f"DROP DATABASE {tool.quote_identifier(name)}")
        self.sql("DROP ROLE app")
        self.sql("DROP ROLE reporting")
        self.sql("CREATE ROLE app LOGIN")
        self.sql("CREATE DATABASE app OWNER app")

        tool.restore(backup_set, assume_yes=False, reconcile_unit=None)
        self.assertEqual(self.sql("SELECT name FROM items ORDER BY id", "app"), ["one", "two"])
        self.assertEqual(self.sql("SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'app'"), ["app"])
        self.assertEqual(self.sql("SHOW work_mem", "app"), ["7MB"])
        self.assertEqual(self.sql("SELECT has_database_privilege('reporting', 'app', 'CONNECT')"), ["t"])
        self.assertEqual(self.sql("SELECT has_table_privilege('reporting', 'items', 'SELECT')", "app"), ["t"])
        self.assertEqual(self.sql("SELECT rolpassword IS NOT NULL FROM pg_authid WHERE rolname = 'app'"), ["t"])
        self.assertIn("odd/name", self.sql("SELECT datname FROM pg_database"))
        self.assertNotIn("staging", self.sql("SELECT datname FROM pg_database"))

    def test_restore_over_data_needs_confirmation(self):
        self.create_cluster()
        backup_set = tool.backup(self.location, [], KEEP)
        self.sql("INSERT INTO items VALUES (3, 'three')", "app")
        with mock.patch("sys.stdin.isatty", return_value=False):
            with self.assertRaisesRegex(tool.Failure, "--yes"):
                tool.restore(backup_set, assume_yes=False, reconcile_unit=None)
        self.assertEqual(self.sql("SELECT count(*) FROM items", "app"), ["3"])
        tool.restore(backup_set, assume_yes=True, reconcile_unit=None)
        self.assertEqual(self.sql("SELECT count(*) FROM items", "app"), ["2"])

    def login(self, password):
        environment = {**os.environ, "PGUSER": "login", "PGPASSWORD": password}
        return subprocess.run(["psql", "-X", "-d", "postgres", "-c", "SELECT 1"], env=environment, capture_output=True).returncode == 0

    def test_set_password_stores_only_a_verifier_that_logs_in(self):
        self.sql("CREATE ROLE login LOGIN")
        for password in ("generated-Password_123", "p\u00e4ss w\u00f6rd\u00a0x"):
            file = self.location / "password"
            file.write_bytes(password.encode() + b"\n")
            tool.set_password("login", file)
            self.assertTrue(self.login(password), password)
            self.assertFalse(self.login(password + "x"))
            stored = self.sql("SELECT rolpassword FROM pg_authid WHERE rolname = 'login'")[0]
            self.assertTrue(stored.startswith("SCRAM-SHA-256$4096:"), stored)
        (self.location / "empty").write_bytes(b"\n")
        with self.assertRaisesRegex(tool.Failure, "holds no password"):
            tool.set_password("login", self.location / "empty")

    def extension_version(self, database):
        return self.sql("SELECT extversion FROM pg_extension WHERE extname = 'hstore'", database)

    def test_update_extensions_brings_every_database_to_the_installed_version(self):
        # As after a package update: the catalog still holds the old version.
        self.sql("CREATE DATABASE app")
        for database in ("app", "template1"):
            self.sql("CREATE EXTENSION hstore VERSION '1.4'", database)
        self.sql("CREATE EXTENSION hstore", "postgres")
        installed = self.sql("SELECT default_version FROM pg_available_extensions WHERE name = 'hstore'")
        tool.update_extensions()
        for database in ("app", "template1", "postgres"):
            self.assertEqual(self.extension_version(database), installed, database)

    def test_update_extensions_leaves_a_catalog_newer_than_the_installed_files(self):
        # As after a rollback: PostgreSQL ships no downgrade scripts.
        directory = self.extensions / "extension"
        (directory / "rollback_probe--1.0.sql").write_text("")
        (directory / "rollback_probe--1.0--2.0.sql").write_text("")
        control = directory / "rollback_probe.control"
        control.write_text("default_version = '2.0'\nrelocatable = true\n")
        self.sql("CREATE EXTENSION rollback_probe")
        control.write_text("default_version = '1.0'\nrelocatable = true\n")
        with mock.patch.object(sys, "stderr", io.StringIO()) as stderr:
            tool.update_extensions()
        self.assertEqual(self.sql("SELECT extversion FROM pg_extension WHERE extname = 'rollback_probe'"), ["2.0"])
        self.assertIn("rollback_probe in postgres", stderr.getvalue())

    def test_failed_dump_discards_the_whole_run(self):
        self.create_cluster()
        earlier = tool.backup(self.location, [], KEEP, now=datetime(2026, 1, 1, tzinfo=timezone.utc))
        real_run = tool.run

        def failing(command, database="postgres", stdin=None):
            if command[0] == "pg_dump" and database == "app":
                raise tool.Failure("pg_dump failed: simulated")
            return real_run(command, database, stdin)

        with mock.patch.object(tool, "run", failing):
            with self.assertRaisesRegex(tool.Failure, "simulated"):
                tool.backup(self.location, [], KEEP)
        self.assertEqual([path for _, path in tool.sets(self.location)], [earlier])
        self.assertFalse(list(self.location.glob(".in-progress-*")))


if __name__ == "__main__":
    unittest.main()
