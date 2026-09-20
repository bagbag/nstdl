"""nstdl: operations on the consuming flake, run from its root.

Everything about the flake comes from the manifest baked at evaluation time
($NSTDL_MANIFEST), so the command follows the consumer's lock and never
evaluates a host itself; $NSTDL_AGENIX is the agenix-rekey command used to
rekey.

Secret values live only in memory and on the stdin of child processes. They
are never passed as arguments and never written unencrypted, except to the
private file `edit` hands to the editor. `set` only creates; an existing
canonical file is only replaced by `rotate` or `edit`, and only when its item
declares `rotate = true`.
"""

import argparse
import base64
import getpass
import hashlib
import hmac
import json
import os
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

EXIT_FAILURE = 1
EXIT_DRIFT = 3

DIGITS = "0123456789"
LOWER = "abcdefghijklmnopqrstuvwxyz"
UPPER = LOWER.upper()
ALPHABETS = {
    "alphanumeric": UPPER + LOWER + DIGITS,
    "alphanumeric-lowercase": LOWER + DIGITS,
}


class Failure(Exception):
    pass


@dataclass(frozen=True)
class Item:
    name: str
    file: Path
    rotate: bool
    generator: dict | None
    hosts: list

    @property
    def source(self) -> str | None:
        return self.generator.get("from") if self.generator else None

    @property
    def entered(self) -> bool:
        """Provided by a person (`set`), not by `sync`."""
        return self.generator is None or (
            self.generator["type"] == "password-hash" and self.source is None
        )


class Manifest:
    def __init__(self, path: str):
        data = json.loads(Path(path).read_text())
        self.recipients: list[str] = data["recipients"]
        self.identities: list[str] = data["identities"]
        self.items = {
            name: Item(
                name=name,
                file=Path(item["file"]),
                rotate=item["rotate"],
                generator=item["generator"],
                hosts=item["hosts"],
            )
            for name, item in data["items"].items()
        }

    def ordered(self) -> list[Item]:
        """Sources before the hashes derived from them."""
        return sorted(self.items.values(), key=lambda item: item.source is not None)

    def dependents(self, name: str) -> list[Item]:
        return [item for item in self.items.values() if item.source == name]


def run(argv: list[str], *, input: str | None = None, stdout=subprocess.PIPE) -> str:
    result = subprocess.run(argv, input=input, stdout=stdout, text=True)
    if result.returncode != 0:
        raise Failure(f"{argv[0]} exited with status {result.returncode}")
    return result.stdout or ""


def random_value(format: str, byte_count: int | None, length: int | None) -> str:
    """Byte formats encode exactly `byte_count` random bytes, so the value
    decodes back to them; character formats draw `length` characters
    uniformly from their alphabet."""
    match format:
        case "hex":
            return secrets.token_bytes(byte_count).hex()
        case "base64":
            return base64.b64encode(secrets.token_bytes(byte_count)).decode()
        case "base64url":
            return base64.urlsafe_b64encode(secrets.token_bytes(byte_count)).decode()
    return "".join(secrets.choice(ALPHABETS[format]) for _ in range(length))


# Options that keep an editor from writing the value anywhere else (backups,
# swap, undo history) and from appending a final newline on save; other
# editors are used as they are.
EDITOR_HARDENING = {
    "vim": ["--cmd", 'au BufRead * setlocal nobackup nomodeline noshelltemp noswapfile noundofile nowritebackup nofixendofline viminfo=""'],
    "nvim": ["--cmd", "au BufRead * setlocal nobackup nomodeline noshelltemp noswapfile noundofile nowritebackup nofixendofline shadafile=NONE"],
    "micro": ["-backup", "false", "-eofnewline", "false"],
}


def plaintext_directory() -> str | None:
    """Memory-backed on Linux; macOS has none by default, so $TMPDIR, which is
    per-user and encrypted with the disk."""
    for candidate in (os.environ.get("XDG_RUNTIME_DIR"), "/dev/shm"):
        if candidate and sys.platform.startswith("linux") and os.access(candidate, os.W_OK):
            return candidate
    return None


def edit_in_editor(name: str, value: str) -> str:
    """The only place a value is ever written unencrypted: a private file for
    the editor, removed however the editor or this process ends (except kill -9)."""
    editor = shlex.split(os.environ.get("VISUAL") or os.environ.get("EDITOR") or "vi")
    editor += EDITOR_HARDENING.get(os.path.basename(editor[0]), [])
    directory = tempfile.mkdtemp(prefix="nstdl-", dir=plaintext_directory())
    try:
        path = Path(directory) / name
        path.touch(mode=0o600)
        path.write_text(value)
        run([*editor, str(path)], stdout=None)
        edited = path.read_text()
        # An editor without the options above may still append one.
        return edited if value.endswith("\n") else edited.removesuffix("\n")
    finally:
        shutil.rmtree(directory, ignore_errors=True)


class Secrets:
    def __init__(self, manifest: Manifest, agenix: str, assume_yes: bool):
        self.manifest = manifest
        self.agenix = agenix
        self.assume_yes = assume_yes

    # -- guards --------------------------------------------------------------

    def require_changes_allowed(self) -> None:
        if not self.assume_yes and not sys.stdin.isatty():
            raise Failure("refusing to change secrets without a terminal; pass --yes to allow it")

    # -- age -----------------------------------------------------------------

    def identity_args(self) -> list[str]:
        readable = [
            path
            for path in (os.path.expanduser(identity) for identity in self.manifest.identities)
            if os.access(path, os.R_OK)
        ]
        if not readable:
            configured = ", ".join(self.manifest.identities)
            raise Failure(f"none of the configured administrator identities is readable on this machine: {configured}")
        return [arg for path in readable for arg in ("-i", path)]

    def decrypt(self, item: Item) -> str:
        if not item.file.exists():
            raise Failure(f"'{item.name}' has no value yet")
        return run(["rage", "-d", *self.identity_args(), str(item.file)])

    def store(self, item: Item, value: str, *, replace: bool) -> None:
        """Encrypts beside the target, then publishes: `create` never
        overwrites (a hard link fails on an existing name), `replace` swaps
        atomically."""
        if not value:
            raise Failure(f"refusing to store an empty value for '{item.name}'")
        item.file.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(dir=item.file.parent, prefix=".nstdl.", suffix=".age")
        try:
            recipients = [arg for recipient in self.manifest.recipients for arg in ("-r", recipient)]
            with os.fdopen(descriptor, "wb") as output:
                run(["rage", "-e", *recipients], input=value, stdout=output)
            if replace:
                os.replace(temporary, item.file)
            else:
                try:
                    os.link(temporary, item.file)
                except FileExistsError:
                    raise Failure(f"'{item.file}' already exists; nothing was overwritten") from None
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        self.git_add(item.file)
        print(f"  {'replaced' if replace else 'created'} {item.name} ({item.file})", file=sys.stderr)

    @staticmethod
    def git_add(path: Path) -> None:
        # An untracked file is invisible to flake evaluation.
        inside = subprocess.run(
            ["git", "rev-parse", "--is-inside-work-tree"],
            cwd=path.parent,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if inside.returncode == 0:
            run(["git", "-C", str(path.parent), "add", "--", path.name])

    def rekey(self) -> None:
        print("Rekeying for the hosts...", file=sys.stderr)
        run([self.agenix, "rekey", "-a"], stdout=None)

    # -- values --------------------------------------------------------------

    @staticmethod
    def prompt_password(name: str) -> str:
        password = getpass.getpass(f"Password for {name}: ")
        if not password or password != getpass.getpass("Confirm: "):
            raise Failure("passwords are empty or do not match")
        return password

    def generate(self, item: Item) -> str:
        generator = item.generator
        match generator["type"]:
            case "random":
                return random_value(generator["format"], generator["bytes"], generator["length"])
            case "passphrase":
                # Every parameter is passed explicitly. Left implicit, xkcdpass'
                # own defaults decide the strength, and they are not the ones to
                # want: `--min 5 --max 9` is strictly worse on both axes at once.
                # `--max 9` does nothing (eff-long's longest word is 9
                # characters), while `--min 5` drops 549 of the 7776 words —
                # lowering entropy to 76.9 bits AND raising the average length
                # typed. Dropping the length filter gives 77.5 bits in one
                # character less.
                #
                # `--valid-chars` is composed into `^[a-z]{1,99}$` together with
                # the length bounds, so it anchors the whole word rather than
                # its first character. On eff-long it removes exactly four
                # hyphenated entries (drop-down, felt-tip, t-shirt, yo-yo),
                # leaving 7772 words and 6 x log2(7772) = 77.5 bits — a cost of
                # 0.01 bits to lose the words whose spelling is ambiguous to
                # read back over a console. It also keeps the value ASCII if the
                # wordlist above is ever changed: ger-anlx, for instance, is
                # 63% capitalised or umlauted entries. Lowercase and
                # space-separated so it types identically on whatever keyboard
                # layout a recovery console offers.
                #
                # `--allow-weak-rng` is deliberately never passed: xkcdpass then
                # fails rather than silently falling back to a weak RNG.
                words = run([
                    "xkcdpass",
                    "--wordfile", "eff-long",
                    "--min", "1",
                    "--max", "99",
                    "--valid-chars", "[a-z]",
                    "--case", "lower",
                    "--delimiter", " ",
                    "--numwords", str(generator["words"]),
                ])
                return words.strip()
            case "password-hash":
                if item.source is None:
                    password = self.prompt_password(item.name)
                else:
                    password = self.decrypt(self.manifest.items[item.source])
                if not password:
                    raise Failure(f"refusing to hash an empty password for '{item.name}'")
                return run(["mkpasswd", "--method=yescrypt", "--stdin"], input=password).strip()
        raise Failure(f"unknown generator type {generator['type']!r}")

    def refresh_dependents(self, item: Item) -> None:
        """Re-derives the hashes computed from ITEM after ITEM changed; this is
        the only way a derived value is ever replaced."""
        for dependent in self.manifest.dependents(item.name):
            self.store(dependent, self.generate(dependent), replace=dependent.file.exists())

    # -- commands ------------------------------------------------------------

    def rekeyed_path(self, item: Item, host: dict) -> Path:
        # agenix-rekey's local storage naming (modules/agenix-rekey.nix,
        # rekeyedLocalSecret); cross-checked by tests/evaluate.sh.
        pubkey_hash = hashlib.sha256(host["pubkey"].encode()).hexdigest()
        file_hash = hashlib.sha256(item.file.read_bytes()).hexdigest()
        identity = hashlib.sha256((pubkey_hash + file_hash).encode()).hexdigest()[:32]
        return Path(host["rekeyedDir"]) / f"{identity}-{item.name}.age"

    def status(self, check: bool) -> int:
        drift = False
        rows = [("SECRET", "STATE", "HOSTS")]
        for item in self.manifest.ordered():
            hosts = []
            if not item.file.exists():
                state = "missing: run set" if item.entered else "missing: run sync"
            else:
                state = "ok"
                for host in item.hosts:
                    if host["rekeyedDir"] is not None and not self.rekeyed_path(item, host).exists():
                        state = "not rekeyed: run sync"
                        hosts.append(f"{host['name']} (pending)")
                    else:
                        hosts.append(host["name"])
            drift = drift or state != "ok"
            rows.append((item.name, state, ", ".join(hosts) or "-"))
        width = max(len(row[0]) for row in rows) + 2
        for name, state, hosts in rows:
            print(f"{name:<{width}}{state:<24}{hosts}")
        return EXIT_DRIFT if check and drift else 0

    def sync(self) -> int:
        self.require_changes_allowed()
        # A hash left over from an earlier source would silently stop matching
        # the source sync is about to generate; replacing it is the operator's call.
        for item in self.manifest.ordered():
            source = self.manifest.items[item.source] if item.source else None
            if source and not source.entered and item.file.exists() and not source.file.exists():
                raise Failure(
                    f"'{item.name}' exists but its source '{source.name}' does not; "
                    f"delete {item.file} explicitly, then run sync again"
                )
        created, pending = 0, []
        for item in self.manifest.ordered():
            if item.file.exists():
                continue
            if item.entered:
                pending.append(item.name)
                continue
            self.store(item, self.generate(item), replace=False)
            created += 1
        print(f"Created {created} secret(s).", file=sys.stderr)
        self.rekey()
        if pending:
            print(f"Still without a value (use `nstdl secret set`): {', '.join(pending)}", file=sys.stderr)
        return 0

    def entered_value(self, item: Item) -> str:
        if item.generator is not None:
            return self.generate(item)
        if sys.stdin.isatty():
            return getpass.getpass(f"Value for {item.name}: ")
        return sys.stdin.read().removesuffix("\n")

    def set(self, item: Item) -> int:
        self.require_changes_allowed()
        if not item.entered:
            raise Failure(f"'{item.name}' is generated; use sync or rotate")
        if item.file.exists():
            raise Failure(f"'{item.name}' already has a value; use rotate to replace it")
        self.store(item, self.entered_value(item), replace=False)
        self.refresh_dependents(item)
        self.rekey()
        return 0

    def edit(self, item: Item) -> int:
        self.require_changes_allowed()
        if not sys.stdin.isatty():
            raise Failure("edit needs a terminal; pipe a new value into rotate instead")
        if item.generator is not None:
            raise Failure(f"'{item.name}' is generated; use rotate")
        if not item.file.exists():
            raise Failure(f"'{item.name}' has no value yet; use set")
        if not item.rotate:
            raise Failure(f"'{item.name}' does not allow replacing its value (rotate = false)")
        old = self.decrypt(item)
        new = edit_in_editor(item.name, old)
        if new == old:
            print(f"'{item.name}' unchanged.", file=sys.stderr)
            return 0
        self.store(item, new, replace=True)
        self.refresh_dependents(item)
        self.rekey()
        return 0

    def rotate(self, item: Item) -> int:
        self.require_changes_allowed()
        if item.source is not None:
            raise Failure(f"'{item.name}' is derived; rotate its source '{item.source}'")
        if not item.rotate:
            raise Failure(f"'{item.name}' does not allow rotation (rotate = false)")
        if not item.file.exists():
            raise Failure(f"'{item.name}' has no value yet; use {'set' if item.entered else 'sync'}")
        if not self.assume_yes:
            if input(f"Replace '{item.name}' for good? Type its name to confirm: ") != item.name:
                raise Failure("not confirmed")
        value = self.entered_value(item) if item.entered else self.generate(item)
        self.store(item, value, replace=True)
        self.refresh_dependents(item)
        self.rekey()
        return 0

    def view(self, item: Item) -> int:
        value = self.decrypt(item)
        sys.stdout.write(value + ("\n" if sys.stdout.isatty() else ""))
        return 0

    def verify(self, item: Item) -> int:
        stored = self.decrypt(item).strip()
        if not stored.startswith("$") or stored.count("$") < 3:
            raise Failure(f"'{item.name}' does not hold a crypt password hash")
        password = getpass.getpass("Password to verify: ")
        # The stored hash without its final field is the setting: method, cost, salt.
        setting = stored.rsplit("$", 1)[0]
        candidate = run(["mkpasswd", f"--salt={setting}", "--stdin"], input=password).strip()
        if not hmac.compare_digest(candidate, stored):
            raise Failure(f"password does not match '{item.name}'")
        print(f"Password matches {item.name}.", file=sys.stderr)
        return 0


def parser(manifest: Manifest) -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(
        prog="nstdl",
        description="Operations on this flake. Run through the ./nstdl wrapper at the flake root.",
        epilog="Exit status: 0 success, 1 failure, 2 usage error, 3 drift (secret status --check).",
    )
    root.add_argument("--yes", action="store_true", help="allow changes without a terminal and skip confirmations")
    nouns = root.add_subparsers(dest="noun", required=True, metavar="COMMAND")

    secret = nouns.add_parser("secret", help="age secrets declared in nstdl.secrets.items")
    verbs = secret.add_subparsers(dest="verb", required=True, metavar="VERB")
    status = verbs.add_parser("status", help="declared secrets, missing values and pending rekeys")
    status.add_argument("--check", action="store_true", help="exit 3 when anything is missing or not rekeyed")
    verbs.add_parser("sync", help="create every missing generated secret, then rekey; run after any declaration change")
    for verb, text in (
        ("set", "enter the first value of an externally issued secret or a self-chosen password"),
        ("edit", "change an externally issued value in $EDITOR (needs rotate = true)"),
        ("rotate", "replace a value: generate a new one or enter it (needs rotate = true)"),
        ("view", "print the decrypted value"),
        ("verify", "check a typed password against a stored password hash"),
    ):
        verbs.add_parser(verb, help=text).add_argument("item", choices=sorted(manifest.items), metavar="ITEM")
    verbs.add_parser("rekey", help="rekey every secret for its hosts")
    return root


def main(argv: list[str]) -> int:
    manifest = Manifest(os.environ["NSTDL_MANIFEST"])
    args = parser(manifest).parse_args(argv)
    try:
        if not Path("flake.nix").is_file():
            raise Failure("run from the flake root (the ./nstdl wrapper does this)")
        commands = Secrets(manifest, os.environ["NSTDL_AGENIX"], args.yes)
        match args.verb:
            case "status":
                return commands.status(args.check)
            case "sync":
                return commands.sync()
            case "rekey":
                commands.require_changes_allowed()
                commands.rekey()
                return 0
            case verb:
                return getattr(commands, verb)(manifest.items[args.item])
    except Failure as failure:
        print(f"nstdl: {failure}", file=sys.stderr)
        return EXIT_FAILURE
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
