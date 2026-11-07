"""Whole-cluster PostgreSQL backup sets, their restore, declared role passwords
and extension updates.

`backup` runs as postgres from nstdl-postgresql-backup.service; `restore` runs
as root through `nstdl postgresql restore`; `set-password` runs as postgres
from nstdl-postgresql-reconcile.service, `update-extensions` from
postgresql-setup.service."""

import argparse
import base64
import hashlib
import hmac
import os
import re
import secrets
import shutil
import stringprep
import subprocess
import sys
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

SET_FORMAT = "%Y-%m-%dT%H%M%SZ"
SET_NAME = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{6}Z$")
IN_PROGRESS = ".in-progress-"
GLOBALS = "globals.sql"

# pg_dumpall's own selection: template0 refuses connections, and -2 marks a
# database an interrupted DROP DATABASE left invalid.
CONNECTABLE_DATABASES = "SELECT datname FROM pg_database WHERE datallowconn AND datconnlimit <> -2 ORDER BY datname"
ALL_DATABASES = "SELECT datname FROM pg_database"
# Tables an extension created (on a rebuilt host, before any data) do not count.
HAS_TABLES = """
SELECT EXISTS (
  SELECT FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p', 'm')
    AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND n.nspname !~ '^pg_(toast|temp_)'
    AND NOT EXISTS (
      SELECT FROM pg_depend d
      WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e'))
"""
# Oldest first, so an extension is updated before those created on top of it.
# Split by whether an update path exists: after a rollback the catalog is newer
# than the files, and extensions ship no downgrade scripts.
OUTDATED_EXTENSIONS = """
SELECT e.extname FROM pg_extension e JOIN pg_available_extensions a ON a.name = e.extname
WHERE e.extversion IS DISTINCT FROM a.default_version AND {} EXISTS (
  SELECT FROM pg_extension_update_paths(e.extname) p
  WHERE p.source = e.extversion AND p.target = a.default_version AND p.path IS NOT NULL)
ORDER BY e.oid
"""
UPDATABLE_EXTENSIONS = OUTDATED_EXTENSIONS.format("")
STRANDED_EXTENSIONS = OUTDATED_EXTENSIONS.format("NOT")
ROLE_EXISTS = re.compile(r'ERROR:\s+role ".*" already exists')
ARCHIVE_DATABASE = re.compile(r"^;\s+dbname: (.*)$", re.MULTILINE)
SCRAM_ITERATIONS = 4096  # PostgreSQL's default scram_iterations
PROHIBITED = (
    stringprep.in_table_a1,
    stringprep.in_table_c12,
    stringprep.in_table_c21,
    stringprep.in_table_c22,
    stringprep.in_table_c3,
    stringprep.in_table_c4,
    stringprep.in_table_c5,
    stringprep.in_table_c6,
    stringprep.in_table_c7,
    stringprep.in_table_c8,
    stringprep.in_table_c9,
)


class Failure(Exception):
    pass


def as_postgres(command: list[str]) -> list[str]:
    # Peer authentication maps the OS user to the role; root has no role.
    return ["runuser", "-u", "postgres", "--", *command] if os.geteuid() == 0 else command


def run(command: list[str], database: str = "postgres", stdin=None, input: str | None = None) -> str:
    # The name goes through the environment: as --dbname, one containing '='
    # would be parsed as a connection string.
    environment = {**os.environ, "PGDATABASE": database}
    result = subprocess.run(as_postgres(command), env=environment, stdin=stdin, input=input, capture_output=True, text=True)
    if result.returncode != 0:
        raise Failure(f"{command[0]} failed: {result.stderr.strip()}")
    return result.stdout


def query(sql: str, database: str = "postgres") -> list[str]:
    output = run(["psql", "-X", "-q", "-A", "-t", "-0", "-v", "ON_ERROR_STOP=1", "-c", sql], database)
    # NUL-separated rows: a database name may contain a newline.
    return [row for row in output.rstrip("\n").split("\0") if row]


def quote_identifier(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def dump_file_name(database: str) -> str:
    """A readable, reversible file name; restore reads the real name from the archive."""
    escaped = database.replace("%", "%25").replace("/", "%2F")
    if escaped.startswith("."):
        escaped = "%2E" + escaped[1:]
    return escaped + ".dump"


def fsync(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def backup(location: Path, exclude: list[str], keep: dict[str, int], now: datetime | None = None) -> Path:
    for leftover in location.glob(IN_PROGRESS + "*"):
        shutil.rmtree(leftover)
    databases = query(CONNECTABLE_DATABASES)
    for name in sorted(set(exclude) - set(databases)):
        print(f"warning: excluded database {name!r} does not exist", file=sys.stderr)
    name = (now or datetime.now(timezone.utc)).strftime(SET_FORMAT)
    work = location / (IN_PROGRESS + name)
    work.mkdir(mode=0o700)
    try:
        for database in databases:
            if database not in exclude:
                run(["pg_dump", "--format=custom", "--compress=zstd", "--file", str(work / dump_file_name(database))], database)
        # Last: a role cannot be dropped while it owns objects or holds
        # privileges, so every role the dumps above reference is still here.
        run(["pg_dumpall", "--globals-only", "--file", str(work / GLOBALS)])
        # Without the syncs, a power loss right after the rename can leave a
        # complete-looking set of empty files.
        for file in work.iterdir():
            fsync(file)
        fsync(work)
        final = location / name
        if final.exists():
            raise Failure(f"backup set {final} already exists")
        work.rename(final)
        fsync(location)
    except BaseException:
        shutil.rmtree(work, ignore_errors=True)
        raise
    prune(location, keep)
    return final


def sets(location: Path) -> list[tuple[datetime, Path]]:
    found = [(datetime.strptime(path.name, SET_FORMAT).replace(tzinfo=timezone.utc), path) for path in location.iterdir() if path.is_dir() and SET_NAME.match(path.name)]
    return sorted(found, reverse=True)


def kept(times: list[datetime], keep: dict[str, int]) -> set[datetime]:
    """The newest set, plus the newest set of each of the last `keep[unit]` days, ISO weeks and months that have one."""
    newest_first = sorted(times, reverse=True)
    result = set(newest_first[:1])
    buckets = {
        "daily": lambda time: time.date(),
        "weekly": lambda time: time.isocalendar()[:2],
        "monthly": lambda time: (time.year, time.month),
    }
    for unit, bucket in buckets.items():
        seen = []
        for time in newest_first:
            if bucket(time) in seen:
                continue
            if len(seen) == keep[unit]:
                break
            seen.append(bucket(time))
            result.add(time)
    return result


def prune(location: Path, keep: dict[str, int]) -> None:
    found = sets(location)
    keep_times = kept([time for time, _ in found], keep)
    for time, path in found:
        if time not in keep_times:
            shutil.rmtree(path)


def archive_database(dump: Path) -> str:
    with dump.open("rb") as archive:
        match = ARCHIVE_DATABASE.search(run(["pg_restore", "--list"], stdin=archive))
    if not match:
        raise Failure(f"{dump} names no database")
    return match.group(1)


def confirm(not_empty: list[str], assume_yes: bool) -> None:
    if not not_empty:
        return
    print("These databases are not empty and will be replaced:", file=sys.stderr)
    for name in not_empty:
        print(f"  {name}", file=sys.stderr)
    if assume_yes:
        return
    if not sys.stdin.isatty():
        raise Failure("refusing to replace databases without a terminal; pass --yes to allow it")
    for name in not_empty:
        if input(f"Type '{name}' to replace it: ") != name:
            raise Failure("not confirmed; nothing was changed")


def restore_globals(path: Path) -> None:
    with path.open("rb") as script:
        result = subprocess.run(as_postgres(["psql", "-X", "-q", "-d", "postgres"]), stdin=script, capture_output=True, text=True)
    # Roles the rebuilt host already declares exist; their CREATE ROLE fails
    # and the ALTER ROLE that follows still applies the backed-up attributes.
    unexpected = [line for line in result.stderr.splitlines() if not ROLE_EXISTS.search(line)]
    if result.returncode != 0 or any("ERROR:" in line or "FATAL:" in line for line in unexpected):
        raise Failure(f"{path}: " + "\n".join(unexpected))


def restore_database(name: str, dump: Path, exists: bool) -> None:
    with dump.open("rb") as archive:
        if name == "template1":
            # template1 cannot be dropped; its contents load in place, without
            # its database-level settings.
            run(["pg_restore", "--clean", "--if-exists", "--exit-on-error", "--dbname", "template1"], stdin=archive)
            return
        maintenance = "template1" if name == "postgres" else "postgres"
        if exists:
            run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", f"DROP DATABASE {quote_identifier(name)} WITH (FORCE)"], maintenance)
        run(["pg_restore", "--create", "--exit-on-error", "--dbname", maintenance], stdin=archive)


def restore(set_path: Path, assume_yes: bool, reconcile_unit: str | None) -> None:
    if not (set_path / GLOBALS).is_file():
        raise Failure(f"{set_path} is not a backup set: {GLOBALS} is missing")
    targets = {archive_database(dump): dump for dump in sorted(set_path.glob("*.dump"))}
    existing = set(query(ALL_DATABASES))
    not_empty = [name for name in sorted(targets) if name in existing and query(HAS_TABLES, name) == ["t"]]
    confirm(not_empty, assume_yes)
    restore_globals(set_path / GLOBALS)
    # The maintenance databases last: restoring postgres drops it, and the
    # others connect through it.
    for name in sorted(targets, key=lambda name: (name in ("postgres", "template1"), name)):
        print(f"restoring {name}", file=sys.stderr)
        restore_database(name, targets[name], name in existing)
    if reconcile_unit:
        # globals.sql carries the backed-up password hashes; this puts the
        # declared passwords, owners and extensions back.
        subprocess.run(["systemctl", "restart", reconcile_unit], check=True)
    print(f"restored {len(targets)} databases and the roles from {set_path}", file=sys.stderr)


def saslprep(password: str) -> bytes:
    """The bytes PostgreSQL hashes (pg_saslprep): SASLprep (RFC 4013), or the
    unchanged password when SASLprep rejects it."""
    raw = password.encode()
    if password.isascii():
        return raw
    mapped = "".join(" " if stringprep.in_table_c12(char) else char for char in password if not stringprep.in_table_b1(char))
    prepared = unicodedata.normalize("NFKC", mapped)
    if not prepared or any(check(char) for char in prepared for check in PROHIBITED):
        return raw
    if any(stringprep.in_table_d1(char) for char in prepared):
        if any(stringprep.in_table_d2(char) for char in prepared) or not (stringprep.in_table_d1(prepared[0]) and stringprep.in_table_d1(prepared[-1])):
            return raw
    return prepared.encode()


def base64_text(data: bytes) -> str:
    return base64.b64encode(data).decode()


def scram_verifier(password: bytes, salt: bytes | None = None) -> str:
    """A SCRAM-SHA-256 verifier in pg_authid's format (RFC 5802/7677)."""
    salt = salt or secrets.token_bytes(16)
    salted = hashlib.pbkdf2_hmac("sha256", password, salt, SCRAM_ITERATIONS)
    stored_key = hashlib.sha256(hmac.digest(salted, b"Client Key", "sha256")).digest()
    server_key = hmac.digest(salted, b"Server Key", "sha256")
    return f"SCRAM-SHA-256${SCRAM_ITERATIONS}:{base64_text(salt)}${base64_text(stored_key)}:{base64_text(server_key)}"


def set_password(role: str, path: Path) -> None:
    # Only the line ending is not part of the password.
    data = path.read_bytes().rstrip(b"\r\n")
    if not data:
        raise Failure(f"{path} holds no password")
    try:
        password = saslprep(data.decode())
    except UnicodeDecodeError:
        password = data
    # The server stores a verifier as given, so the password itself never
    # reaches it, its logs or pg_stat_activity; stdin keeps even the verifier
    # out of command lines.
    run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1"], input=f"ALTER ROLE {quote_identifier(role)} PASSWORD '{scram_verifier(password)}';\n")


def update_extensions() -> None:
    """Update every extension whose catalog version differs from its installed
    files along an update path; warn about the rest."""
    for database in query(CONNECTABLE_DATABASES):
        for extension in query(UPDATABLE_EXTENSIONS, database):
            print(f"updating extension {extension} in {database}", file=sys.stderr)
            run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", f"ALTER EXTENSION {quote_identifier(extension)} UPDATE"], database)
        for extension in query(STRANDED_EXTENSIONS, database):
            print(f"warning: no update path for extension {extension} in {database} to its installed version; left as is", file=sys.stderr)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog=os.environ.get("NSTDL_PROG", "nstdl-postgresql"), description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    backup_command = commands.add_parser("backup", help="write a backup set of every database and the roles")
    backup_command.add_argument("--location", type=Path, required=True)
    backup_command.add_argument("--exclude", action="append", default=[], metavar="DATABASE")
    for unit, default in (("daily", 7), ("weekly", 4), ("monthly", 6)):
        backup_command.add_argument(f"--keep-{unit}", type=int, default=default, metavar="COUNT")
    restore_command = commands.add_parser("restore", help="restore the roles and every database of a backup set")
    restore_command.add_argument("set", type=Path, metavar="SET", help="backup set folder")
    restore_command.add_argument("--yes", action="store_true", help="replace non-empty databases without asking")
    restore_command.add_argument("--reconcile-unit", help=argparse.SUPPRESS)
    password_command = commands.add_parser("set-password", help="set a role's password, hashed here, from a file")
    password_command.add_argument("role")
    password_command.add_argument("file", type=Path)
    commands.add_parser("update-extensions", help="update every extension whose catalog version differs from its installed files")
    return root


def main(argv: list[str]) -> int:
    arguments = parser().parse_args(argv)
    try:
        if arguments.command == "backup":
            keep = {"daily": arguments.keep_daily, "weekly": arguments.keep_weekly, "monthly": arguments.keep_monthly}
            print(f"wrote {backup(arguments.location, arguments.exclude, keep)}", file=sys.stderr)
        elif arguments.command == "restore":
            restore(arguments.set, arguments.yes, arguments.reconcile_unit)
        elif arguments.command == "set-password":
            set_password(arguments.role, arguments.file)
        else:
            update_extensions()
    except Failure as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
