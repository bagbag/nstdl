"""nstdl: operations on the consuming flake, run from its root.

Everything about the flake comes from the manifest baked at evaluation time
($NSTDL_MANIFEST), so the command follows the consumer's lock and never
evaluates a host itself; $NSTDL_AGENIX is the agenix-rekey command used to
rekey and $NSTDL_DEPLOY the deploy-rs binary, present only for a flake that
declares a deployable host.

Secret values live only in memory and on the stdin of child processes. They
are never passed as arguments and never written unencrypted, except to the
private file `edit` hands to the editor. An existing value is replaced only
by `rotate` or `edit` of an item declaring `rotate = true`, by `set --replace`
of an entered value after confirmation, or by re-deriving a hash whenever its
source changes.
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
        # Hosts that set `deployment.enable`.
        self.deploy_nodes: list[str] = data["deploy"]["nodes"]
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
# swap, undo history, viminfo/shada) and from appending a final newline on
# save; other editors are used as they are. `-n` rather than `noswapfile`: the
# autocmd would run only after the swap file already exists.
VIM_HARDENING = ["-n", "-i", "NONE", "--cmd", "au BufRead * setlocal nobackup nomodeline noshelltemp noundofile nowritebackup nofixendofline"]
EDITOR_HARDENING = {
    "vim": VIM_HARDENING,
    "nvim": VIM_HARDENING,
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
    # By the typed name, else the resolved binary: `vi` linked to vim is
    # hardened, a real nvi (which rejects these options) is left alone, and
    # `vim` stays hardened where it resolves to a variant such as vim.basic.
    binary = os.path.basename(os.path.realpath(shutil.which(editor[0]) or editor[0]))
    editor += EDITOR_HARDENING.get(os.path.basename(editor[0])) or EDITOR_HARDENING.get(binary, [])
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
                output.flush()
                os.fsync(output.fileno())
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
        # agenix-rekey asserts that every host-granted secret has a file.
        missing = [item.name for item in self.manifest.items.values() if item.hosts and not item.file.exists()]
        if missing:
            print(f"Rekey deferred until these have a value: {', '.join(missing)}", file=sys.stderr)
            return
        print("Rekeying for the hosts...", file=sys.stderr)
        run([self.agenix, "rekey", "-a"], stdout=None)

    # -- values --------------------------------------------------------------

    @staticmethod
    def prompt_password(name: str) -> str:
        password = getpass.getpass(f"Password for {name}: ")
        if not password or password != getpass.getpass("Confirm: "):
            raise Failure("passwords are empty or do not match")
        return password

    def generate(self, item: Item, source_value: str | None = None) -> str:
        generator = item.generator
        match generator["type"]:
            case "random":
                return random_value(generator["format"], generator["bytes"], generator["length"])
            case "passphrase":
                # Every parameter is explicit so strength is decided here, not by
                # xkcdpass' defaults (`--min 5` drops 549 words). The full
                # eff-long list minus its four hyphenated words, lowercase ASCII,
                # space-separated so it types the same on any console layout.
                # Never `--allow-weak-rng`: xkcdpass then fails rather than fall
                # back to a weak RNG.
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
                elif source_value is not None:
                    password = source_value
                else:
                    password = self.decrypt(self.manifest.items[item.source])
                if not password:
                    raise Failure(f"refusing to hash an empty password for '{item.name}'")
                return run(["mkpasswd", "--method=yescrypt", "--stdin"], input=password).strip()
        raise Failure(f"unknown generator type {generator['type']!r}")

    def publish(self, item: Item, value: str, *, replace: bool) -> None:
        """Stores VALUE with the hashes derived from it, then rekeys. The hashes
        are computed first, so a failure there leaves every file as it was."""
        derived = [(dependent, self.generate(dependent, value)) for dependent in self.manifest.dependents(item.name)]
        self.store(item, value, replace=replace)
        for dependent, digest in derived:
            self.store(dependent, digest, replace=dependent.file.exists())
        self.rekey()

    def confirm_replace(self, item: Item) -> None:
        if not self.assume_yes:
            if input(f"Replace '{item.name}' for good? Type its name to confirm: ") != item.name:
                raise Failure("not confirmed")

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
            source = self.manifest.items.get(item.source)
            if not item.file.exists():
                if source and source.entered and not source.file.exists():
                    state = f"missing: run set {source.name}"
                else:
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
        name_width = max(len(row[0]) for row in rows) + 2
        state_width = max(len(row[1]) for row in rows) + 2
        for name, state, hosts in rows:
            print(f"{name:<{name_width}}{state:<{state_width}}{hosts}")
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
        created, pending, values = 0, [], {}
        for item in self.manifest.ordered():
            if item.file.exists():
                continue
            if item.entered:
                pending.append(item.name)
                continue
            source = self.manifest.items.get(item.source)
            if source and source.name not in values and not source.file.exists():
                pending.append(f"{item.name} (set {source.name})")
                continue
            values[item.name] = self.generate(item, values.get(item.source))
            self.store(item, values[item.name], replace=False)
            created += 1
        print(f"Created {created} secret(s).", file=sys.stderr)
        if pending:
            print(f"Still without a value (use `nstdl secret set`): {', '.join(pending)}", file=sys.stderr)
        self.rekey()
        return 0

    def entered_value(self, item: Item) -> str:
        if item.generator is not None:
            return self.generate(item)
        if sys.stdin.isatty():
            return getpass.getpass(f"Value for {item.name}: ")
        return sys.stdin.read().removesuffix("\n")

    def set(self, item: Item, replace: bool = False) -> int:
        self.require_changes_allowed()
        if not item.entered:
            raise Failure(f"'{item.name}' is generated; use sync or rotate")
        exists = item.file.exists()
        if exists and not replace:
            raise Failure(f"'{item.name}' already has a value; use set --replace to correct it")
        if exists:
            self.confirm_replace(item)
        self.publish(item, self.entered_value(item), replace=exists)
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
        self.publish(item, new, replace=True)
        return 0

    def rotate(self, item: Item) -> int:
        self.require_changes_allowed()
        if item.source is not None:
            raise Failure(f"'{item.name}' is derived; rotate its source '{item.source}'")
        if not item.rotate:
            raise Failure(f"'{item.name}' does not allow rotation (rotate = false)")
        if not item.file.exists():
            raise Failure(f"'{item.name}' has no value yet; use {'set' if item.entered else 'sync'}")
        self.confirm_replace(item)
        self.publish(item, self.entered_value(item) if item.entered else self.generate(item), replace=True)
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


# -- deploy ------------------------------------------------------------------
#
# A spelling, not a safeguard. deploy-rs already refuses to deploy a host whose
# secrets are missing or stale: agenix-rekey asserts on both the canonical file
# and the content-addressed rekeyed one while the profile is evaluated
# (`modules/agenix-rekey.nix`, `rekeyedLocalSecret`), and that survives
# `--skip-checks`, which only drops `nix flake check`. A pre-flight here would
# re-check the same invariant less precisely — against the working tree rather
# than the git tree evaluation sees, and across every host rather than the one
# being deployed. So there is none.


def deploy_argv(nodes: list[str], host: str, rest: list[str]) -> list[str]:
    """deploy-rs' arguments. Everything after the host goes through untouched:
    deploy-rs' flag surface is large and moves, so a curated copy here would be
    a second thing to keep in sync. argparse.REMAINDER has already consumed the
    optional separating `--`; any further one is deploy-rs' own."""
    if not nodes:
        raise Failure("no host in this flake sets deployment.enable")
    if host not in nodes:
        raise Failure(f"unknown host '{host}'; this flake deploys: {', '.join(sorted(nodes))}")
    return [f".#{host}", *rest]


def deploy(manifest: Manifest, host: str, rest: list[str]) -> int:
    arguments = deploy_argv(manifest.deploy_nodes, host, rest)
    # Set whenever a node is declared: the module derives both from one list.
    binary = os.environ["NSTDL_DEPLOY"]
    print(f"Deploying {host}...", file=sys.stderr)
    # exec, not a child: deploy-rs owns the terminal from here — its progress
    # output, an interactive sudo prompt, the magic-rollback confirmation, and
    # Ctrl-C reaching the activation rather than this wrapper.
    os.execv(binary, [binary, *arguments])


def parser(manifest: Manifest) -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(
        prog="nstdl",
        description="Operations on this flake: its age secrets and its deployable hosts. "
        "Run through the ./nstdl wrapper at the flake root.",
        epilog="Exit status: 0 success, 1 failure, 2 usage error, 3 drift (secret status --check). "
        "`deploy` passes deploy-rs's own status through.",
    )
    root.add_argument("--yes", action="store_true", help="allow changes without a terminal and skip confirmations")
    nouns = root.add_subparsers(dest="noun", required=True, metavar="COMMAND")

    secret = nouns.add_parser("secret", help="age secrets declared in nstdl.secrets.items")
    verbs = secret.add_subparsers(dest="verb", required=True, metavar="VERB")
    status = verbs.add_parser("status", help="declared secrets, missing values and pending rekeys")
    status.add_argument("--check", action="store_true", help="exit 3 when anything is missing or not rekeyed")
    verbs.add_parser("sync", help="create every missing generated secret, then rekey; run after any declaration change")
    for verb, text in (
        ("set", "enter the value of an externally issued secret or a self-chosen password"),
        ("edit", "change an externally issued value in $EDITOR (needs rotate = true)"),
        ("rotate", "replace a value: generate a new one or enter it (needs rotate = true)"),
        ("view", "print the decrypted value"),
        ("verify", "check a typed password against a stored password hash"),
    ):
        command = verbs.add_parser(verb, help=text)
        command.add_argument("item", choices=sorted(manifest.items), metavar="ITEM")
        if verb == "set":
            command.add_argument("--replace", action="store_true", help="correct an existing entered value, after typing its name to confirm")
    verbs.add_parser("rekey", help="rekey every secret for its hosts")

    # A noun taking an argument rather than a verb: there is one thing to do to
    # a host, and `nstdl deploy app-01` is the whole point of the wrapper.
    deploy = nouns.add_parser("deploy", help="build and activate a host with deploy-rs")
    deploy.add_argument(
        "host",
        metavar="HOST",
        help=", ".join(sorted(manifest.deploy_nodes)) or "no host in this flake is deployable",
    )
    # Not `choices`: for a flake with no deployable host argparse could only
    # say "invalid choice"; `deploy_argv` says why.
    deploy.add_argument(
        "rest",
        nargs=argparse.REMAINDER,
        metavar="[-- DEPLOY-RS ARGUMENTS]",
        help="passed through untouched, e.g. --dry-activate",
    )
    return root


def main(argv: list[str]) -> int:
    manifest = Manifest(os.environ["NSTDL_MANIFEST"])
    args = parser(manifest).parse_args(argv)
    try:
        if not Path("flake.nix").is_file():
            raise Failure("run from the flake root (the ./nstdl wrapper does this)")
        if args.noun == "deploy":
            return deploy(manifest, args.host, args.rest)
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
            case "set":
                return commands.set(manifest.items[args.item], args.replace)
            case verb:
                return getattr(commands, verb)(manifest.items[args.item])
    except Failure as failure:
        print(f"nstdl: {failure}", file=sys.stderr)
        return EXIT_FAILURE
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
