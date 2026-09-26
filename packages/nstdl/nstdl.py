"""nstdl: operations on the consuming flake, run from its root.

Secrets and deploy discovery come from the manifest baked at evaluation time
($NSTDL_MANIFEST). Installation evaluates only the selected host from the same
frozen consumer flake. $NSTDL_AGENIX is the agenix-rekey command used to rekey
and $NSTDL_DEPLOY the deploy-rs binary, present only for a flake that declares
a deployable host. `nix`, `ssh` and `nom` come from PATH.

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
import re
import secrets
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
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
        # Hosts that set `deployment.enable`, with their SSH destination.
        self.deploy_nodes: dict[str, dict] = data["deploy"]["nodes"]
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


def run(argv: list[str], *, input: str | None = None, stdout=subprocess.PIPE, env: dict | None = None) -> str:
    result = subprocess.run(argv, input=input, stdout=stdout, text=True, env=env)
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

    def derived_matches(self, item: Item) -> bool:
        """Check a stored crypt hash using its own setting and current source."""
        stored = self.decrypt(item).strip()
        if not stored.startswith("$") or stored.count("$") < 3:
            return False
        source_value = self.decrypt(self.manifest.items[item.source])
        if not source_value:
            return False
        setting = stored.rsplit("$", 1)[0]
        candidate = run(["mkpasswd", f"--salt={setting}", "--stdin"], input=source_value).strip()
        return hmac.compare_digest(candidate, stored)

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
                if source and not source.file.exists():
                    state = f"source missing: run {'set' if source.entered else 'sync'} {source.name}"
                elif source:
                    try:
                        if not self.derived_matches(item):
                            state = "out of sync: run sync"
                    except Failure:
                        state = "cannot verify source/hash"
                if state == "ok":
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
        stale = set()
        for item in self.manifest.ordered():
            source = self.manifest.items[item.source] if item.source else None
            if source and item.file.exists() and not source.file.exists():
                raise Failure(
                    f"'{item.name}' exists but its source '{source.name}' does not; "
                    f"delete {item.file} explicitly, then run sync again"
                )
            if source and item.file.exists() and not self.derived_matches(item):
                stale.add(item.name)
        created, repaired, pending, values = 0, 0, [], {}
        for item in self.manifest.ordered():
            if item.file.exists():
                if item.name in stale:
                    self.store(item, self.generate(item), replace=True)
                    repaired += 1
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
        if repaired:
            print(f"Repaired {repaired} derived hash(es).", file=sys.stderr)
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


NSTDL_DEPLOY_OPTIONS = ("--no-rollback", "--diff-files")


def require_host(nodes: dict, host: str) -> None:
    if not nodes:
        raise Failure("no host in this flake sets deployment.enable")
    if host not in nodes:
        raise Failure(f"unknown host '{host}'; this flake deploys: {', '.join(sorted(nodes))}")


def deploy_argv(nodes, host: str, rest: list[str], no_rollback: bool = False) -> list[str]:
    """Keep the preview's host, account and build aligned with deploy-rs."""
    require_host(nodes, host)
    # REMAINDER swallows anything after the host, so a misplaced nstdl option
    # would reach deploy-rs as an unknown flag.
    misplaced = [argument for argument in rest if argument in NSTDL_DEPLOY_OPTIONS]
    if misplaced:
        raise Failure(f"put {', '.join(misplaced)} before the host: nstdl deploy {misplaced[0]} {host}")
    preview_overrides = {
        "--hostname", "--ssh-user", "--profile-user", "--ssh-opts",
        "--sudo", "--groups", "--targets", "--file", "-f",
    }

    def overrides_preview(argument: str) -> bool:
        if argument == "--" or argument.split("=", 1)[0] in preview_overrides:
            return True
        return argument.startswith("-") and not argument.startswith("--") and "f" in argument[1:]

    unsupported = next((argument for argument in rest if overrides_preview(argument)), None)
    if unsupported is not None:
        raise Failure(
            f"deploy-rs option {unsupported!r} can change the previewed target or build; "
            "use deploy-rs directly for that option"
        )
    # Both: magic rollback reverts when the deployer cannot confirm the new
    # generation over a fresh connection, auto rollback when activation fails.
    rollback = ["--magic-rollback", "false", "--auto-rollback", "false"] if no_rollback else []
    return [f".#{host}", *rollback, *rest]


def build_with_nom(argv: list[str]) -> str:
    """Runs a `nix build --print-out-paths` with its log rendered by nom;
    returns the single output path."""
    build = subprocess.Popen(
        [*argv, "--log-format", "internal-json", "-v"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    monitor = subprocess.run(["nom", "--json"], stdin=build.stderr, stdout=sys.stderr)
    output = build.stdout.read()
    build.wait()
    if build.returncode != 0:
        raise Failure(f"build failed (nix exited with status {build.returncode})")
    if monitor.returncode != 0:
        raise Failure(f"nom exited with status {monitor.returncode}")
    return output.strip()


def store_name(path: str) -> str:
    """`/nix/store/<hash>-name` -> `name`."""
    return path.rsplit("/", 1)[-1].split("-", 1)[-1]


def rebuilt(old: list[str], new: list[str]) -> list[str]:
    """Names present in both closures under a different path: what a change
    rebuilt, including the configuration files a package diff cannot show."""
    old_names = {store_name(path) for path in old}
    added = set(new) - set(old)
    return sorted({store_name(path) for path in added} & old_names)


def stopped_wants(show: str) -> list[str]:
    """From `systemctl show -p Id,LoadState,ActiveState,ConditionResult`: the
    loaded units that are not running and whose last condition check passed —
    the ones a start of the target that wants them starts again."""
    stopped = []
    for block in show.strip().split("\n\n"):
        unit = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
        loaded = unit.get("LoadState") == "loaded"
        down = unit.get("ActiveState") in ("inactive", "failed")
        if loaded and down and unit.get("ConditionResult") != "no":
            stopped.append(unit["Id"])
    return sorted(stopped)


def remote_script(target: str, script: str) -> str:
    return run(["ssh", target, "sh -s"], input="set -e\n" + script)


def home_generations(target: str, system: str) -> dict[str, str]:
    """Read the HM generations the system's service units will activate."""
    output = remote_script(target, f'''for unit in {shlex.quote(system)}/etc/systemd/system/home-manager-*.service; do
  [ -e "$unit" ] || continue
  awk -v unit="${{unit##*/}}" '
    /^User=/ {{ user=substr($0, 6) }}
    /^ExecStart=/ {{ start=substr($0, 11) }}
    END {{ printf "%s\\t%s\\t%s\\n", unit, user, start }}
  ' "$unit"
done
''')
    generations = {}
    for line in output.splitlines():
        unit, user, start = line.split("\t", 2)
        match = re.search(r"/nix/store/[a-z0-9]{32}-home-manager-generation(?=\s|/|$)", start)
        if not user or not match or user in generations:
            raise Failure(f"cannot identify Home Manager user/generation in {system}: {unit}")
        generations[user] = match.group()
    return generations


def commands(target: str, paths: list[str]) -> set[str]:
    script = "for directory in " + " ".join(shlex.quote(path) for path in paths) + '''; do
  [ -d "$directory" ] || continue
  find -L "$directory" -mindepth 1 -maxdepth 1 -type f -executable -printf '%f\\n'
done
'''
    return set(remote_script(target, script).splitlines())


def show_diff(target: str, host: str, system: str, diff_files: bool) -> None:
    """Compare a built candidate to the host's running system."""
    nix = ["nix", "--extra-experimental-features", "nix-command"]
    current = run(["ssh", target, "readlink", "-f", "/run/current-system"]).strip()
    if not current.startswith("/nix/store/"):
        raise Failure(f"cannot resolve {host}'s running system")
    print(f"\n{host}: {current} -> {system}\n\nPackages:", file=sys.stderr)
    packages = run(["ssh", target, *nix, "store", "diff-closures", current, system])
    print(packages.rstrip() or "  (none)", file=sys.stderr)

    old, new = (run(["ssh", target, *nix, "path-info", "--recursive", path]).split() for path in (current, system))
    names = rebuilt(old, new)
    print(f"\nRebuilt ({len(names)}):", file=sys.stderr)
    shown = 40
    for name in names[:shown]:
        print(f"  {name}", file=sys.stderr)
    if len(names) > shown:
        print(f"  ... and {len(names) - shown} more", file=sys.stderr)

    old_home = home_generations(target, current)
    new_home = home_generations(target, system)
    users = sorted(set(old_home) | set(new_home))
    before_system = commands(target, [f"{current}/sw/bin"])
    after_system = commands(target, [f"{system}/sw/bin"])
    print(f"\nSystem PATH commands: -{', '.join(sorted(before_system - after_system)) or '(none)'}; +{', '.join(sorted(after_system - before_system)) or '(none)'}", file=sys.stderr)
    for user in users:
        if user not in old_home or user not in new_home:
            state = "added" if user in new_home else "removed"
            generation = new_home.get(user) or old_home[user]
            print(f"\nHome Manager {user}: {state} generation {generation}", file=sys.stderr)
            other = "previous" if state == "added" else "candidate"
            print(f"  No {other} Home Manager generation to compare packages or files; declared command changes follow below.", file=sys.stderr)
            if state == "removed":
                print("  Existing files in the user's home are not removed by this comparison.", file=sys.stderr)
            continue
        previous, candidate = old_home[user], new_home[user]
        print(f"\nHome Manager {user} packages:", file=sys.stderr)
        old_path = run(["ssh", target, "readlink", "-f", f"{previous}/home-path"]).strip()
        new_path = run(["ssh", target, "readlink", "-f", f"{candidate}/home-path"]).strip()
        packages = run(["ssh", target, *nix, "store", "diff-closures", old_path, new_path])
        print(packages.rstrip() or "  (none)", file=sys.stderr)
        print(f"Home Manager {user} files:", file=sys.stderr)
        files = subprocess.run(["ssh", target, "diff", "-qr", f"{previous}/home-files", f"{candidate}/home-files"], stdout=sys.stderr)
        if files.returncode > 1:
            raise Failure(f"Home Manager file diff for {user} exited with status {files.returncode}")

    if users:
        print("\nDeclared PATH commands by Home Manager user:", file=sys.stderr)
        for user in users:
            old_paths = [f"{current}/sw/bin", f"{current}/etc/profiles/per-user/{user}/bin"]
            new_paths = [f"{system}/sw/bin", f"{system}/etc/profiles/per-user/{user}/bin"]
            if user in old_home:
                old_paths.append(f"{old_home[user]}/home-path/bin")
            if user in new_home:
                new_paths.append(f"{new_home[user]}/home-path/bin")
            before, after = commands(target, old_paths), commands(target, new_paths)
            removed, added = sorted(before - after), sorted(after - before)
            print(f"  {user}: -{', '.join(removed) or '(none)'}; +{', '.join(added) or '(none)'}", file=sys.stderr)

    if diff_files:
        print("\nFiles:", file=sys.stderr)
        files = subprocess.run(["ssh", target, "diff", "-ru", f"{current}/etc", f"{system}/etc"], stdout=sys.stderr)
        if files.returncode > 1:
            raise Failure(f"diff of {host}'s /etc exited with status {files.returncode}")


def preview(host: str, node: dict, remote_build: bool, diff_files: bool, mode: str = "switch") -> None:
    """Builds the host's system, puts it on the host and prints what changes
    against the running one — before deploy-rs, which then finds the build
    and the copy already done. Everything runs on the host: only there are
    both closures present."""
    target = f"{node['sshUser']}@{node['hostname']}"
    installable = f".#nixosConfigurations.{host}.config.system.build.toplevel"
    if remote_build:
        # What deploy-rs' --remote-build does: the derivations travel, the
        # build runs on the host.
        derivation = run(["nix", "path-info", "--derivation", installable]).strip()
        run(["nix", "copy", "--substitute-on-destination", "--derivation", "--to", f"ssh-ng://{target}", derivation])
        system = build_with_nom(["nix", "build", "--no-link", "--print-out-paths", "--store", f"ssh-ng://{target}", f"{derivation}^out"])
    else:
        system = build_with_nom(["nix", "build", "--no-link", "--print-out-paths", installable])
        print(f"Copying to {target}...", file=sys.stderr)
        run(["nix", "copy", "--substitute-on-destination", "--to", f"ssh://{target}", system])
    show_diff(target, host, system, diff_files)

    if mode == "boot only":
        print("\nUnits: boot mode updates the boot loader; it does not activate units now.", file=sys.stderr)
        return

    # Root only (switch-to-configuration refuses otherwise), so sudo — which
    # may ask for a password, hence the terminal. Informational: the question
    # below still gates activation.
    print("\nUnits:", file=sys.stderr)
    sudo = [] if node["sshUser"] == "root" else ["sudo"]
    terminal = ["-t"] if sys.stdin.isatty() else []
    units = subprocess.run(["ssh", *terminal, target, *sudo, f"{system}/bin/switch-to-configuration", "dry-activate"], stdout=sys.stderr)
    if units.returncode != 0:
        print(f"  (unit preview failed with status {units.returncode})", file=sys.stderr)

    # dry-activate lists only what the switch acts on itself. The switch also
    # stops and restarts multi-user.target, which starts every unit it wants
    # that is not running — a service stopped by hand included.
    wants = run(["ssh", target, "ls", f"{system}/etc/systemd/system/multi-user.target.wants"]).split()
    if wants:
        show = run(["ssh", target, "systemctl", "show", "-p", "Id,LoadState,ActiveState,ConditionResult", *wants])
        stopped = stopped_wants(show)
        if stopped:
            print(f"would start again (wanted by multi-user.target, not running): {', '.join(stopped)}", file=sys.stderr)


def deploy(manifest: Manifest, host: str, rest: list[str], no_rollback: bool, diff_files: bool, assume_yes: bool) -> int:
    arguments = deploy_argv(manifest.deploy_nodes, host, rest, no_rollback)
    options = arguments[1:]
    # Set whenever a node is declared: the module derives both from one list.
    binary = os.environ["NSTDL_DEPLOY"]
    if not assume_yes and not sys.stdin.isatty():
        raise Failure("refusing to deploy without a terminal; pass --yes to allow it")
    mode = next((name for flag, name in (("--boot", "boot only"), ("--test", "test activation"), ("--dry-activate", "dry activation")) if flag in options), "switch")
    print(f"Deploy mode: {mode}.", file=sys.stderr)
    preview(host, manifest.deploy_nodes[host], "--remote-build" in options, diff_files, mode)
    if no_rollback:
        print("Rollback disabled: a failed activation stays in place.", file=sys.stderr)
    if not assume_yes and input(f"Run {mode} on {host}? [y/N] ").strip().lower() not in ("y", "yes"):
        print("Not deployed.", file=sys.stderr)
        return EXIT_FAILURE
    print(f"Deploying {host}...", file=sys.stderr)
    # exec, not a child: deploy-rs owns the terminal from here — its progress
    # output, an interactive sudo prompt, the magic-rollback confirmation, and
    # Ctrl-C reaching the activation rather than this wrapper.
    os.execv(binary, [binary, *arguments])


def diff(manifest: Manifest, host: str, remote_build: bool, diff_files: bool) -> int:
    require_host(manifest.deploy_nodes, host)
    preview(host, manifest.deploy_nodes[host], remote_build, diff_files)
    return 0


# -- install -----------------------------------------------------------------


def install_config_ref(host: str) -> str:
    metadata = json.loads(run(["nix", "flake", "metadata", "--json", "--no-write-lock-file", "."]))
    source = metadata["path"]
    if not Path(source).is_relative_to("/nix/store"):
        raise Failure("Nix did not resolve this flake to an immutable store snapshot")
    if source != os.environ["NSTDL_SOURCE"]:
        raise Failure("the flake changed since this nstdl binary was built; rerun ./nstdl from this checkout")
    return f"path:{source}#nixosConfigurations.{json.dumps(host)}.config"


def install_eval(config_ref: str, attr: str, apply: str | None = None):
    argv = ["nix", "eval", "--json", config_ref + (f".{attr}" if attr else "")]
    if apply is not None:
        argv += ["--apply", apply]
    return json.loads(run(argv))


def install_shell(target: str | None, script: str) -> str:
    if target is None:
        return run(["sh", "-s"], input="set -e\n" + script)
    # Match the selected upstream transport policy. This does not authenticate
    # the installer endpoint, even if a separate SSH probe succeeded earlier.
    return run([
        "ssh", "-o", "UserKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=10", target, "sh -s",
    ], input="set -e\n" + script)


def install_disk_facts(target: str | None, devices: dict[str, str]) -> dict[str, tuple]:
    facts = {}
    for name, device in devices.items():
        if not re.fullmatch(r"/dev/[A-Za-z0-9_./+-]+", device) or ".." in Path(device).parts:
            raise Failure(f"unsupported Disko device path for '{name}': {device}")
        output = install_shell(target, f"readlink -f {shlex.quote(device)}\nlsblk --json --bytes --output PATH,SIZE,TYPE,MOUNTPOINTS {shlex.quote(device)}\n")
        resolved, _, listing = output.partition("\n")
        blocks = json.loads(listing)["blockdevices"]
        if len(blocks) != 1 or blocks[0]["type"] != "disk":
            raise Failure(f"'{device}' is not one whole disk on {target or 'this installer'}")
        disk = blocks[0]
        facts[name] = (resolved, int(disk["size"]), disk["type"])

        def mounted(block: dict) -> list[str]:
            return [mount for mount in (block.get("mountpoints") or []) if mount] + [
                mount for child in (block.get("children") or []) for mount in mounted(child)
            ]
        mounts = mounted(disk)
        print(f"  {name}: {device} -> {resolved}, {disk['size']} bytes; mounts: {', '.join(mounts) or '(none)'}", file=sys.stderr)
        if mounts:
            facts[name] = (*facts[name], "mounted")
    resolved = [fact[0] for fact in facts.values()]
    if len(set(resolved)) != len(resolved):
        raise Failure("multiple Disko disk names resolve to the same device")
    return facts


def is_installer(target: str | None) -> bool:
    release = install_shell(target, "cat /etc/os-release\n")
    fields = dict(match.groups() for match in re.finditer(r'^([A-Z_]+)="?([^"\n]*)"?$', release, re.M))
    return fields.get("ID") == "nixos" and fields.get("VARIANT_ID") == "installer"


def require_installer(target: str | None) -> None:
    if not is_installer(target):
        raise Failure(f"{target or 'this machine'} must be booted into a NixOS installer")


def confirm_install(host: str, devices: dict[str, str], action: str) -> None:
    confirmation = f"{host} {' '.join(devices.values())}"
    if input(f"{action}; this destroys contents on these disks. Type '{confirmation}' to proceed: ") != confirmation:
        raise Failure("installation not confirmed")


def require_unmounted(facts: dict[str, tuple]) -> None:
    if any(len(fact) > 3 for fact in facts.values()):
        raise Failure("a selected disk is mounted in the installer; no disk was formatted")


def require_empty_install_root(target: str | None) -> None:
    occupied = install_shell(target, "if mountpoint -q /mnt; then printf occupied; fi\n")
    if occupied:
        raise Failure("/mnt is already mounted in the installer; no disk was formatted")


def stage_install_key(source_path: str, key_path: str, staging: Path) -> tuple[Path, str]:
    source = Path(source_path).expanduser()
    staged = staging / key_path.lstrip("/")
    staged.parent.mkdir(parents=True)
    try:
        with source.open("rb") as original:
            info = os.fstat(original.fileno())
            if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
                raise Failure(f"host key must be a private file readable only by its owner: {source}")
            descriptor = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as copy:
                shutil.copyfileobj(original, copy)
    except OSError as error:
        raise Failure(f"cannot stage host key {source}: {error.strerror}") from error
    public = installed_public_key(staged)
    staged.with_name(staged.name + ".pub").write_text(public + "\n")
    return staged, public


def installed_public_key(private: Path) -> str:
    if not private.is_file() or stat.S_IMODE(private.stat().st_mode) & 0o077:
        raise Failure(f"host key must be a private file readable only by its owner: {private}")
    public = run(["ssh-keygen", "-y", "-P", "", "-f", str(private)]).split()
    if len(public) < 2 or public[0] != "ssh-ed25519":
        raise Failure("--host-key must be an unencrypted Ed25519 private key")
    return " ".join(public[:2])


def verify_install(target: str, public: str, system: str, key_path: str, secrets: dict, mounts: dict, directory: Path) -> None:
    known_hosts = directory / "known_hosts"
    known_hosts.write_text(f"nstdl-installed {public}\n")
    ssh = [
        "ssh", "-o", "HostKeyAlias=nstdl-installed",
        "-o", f"UserKnownHostsFile={known_hosts}",
        "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=yes",
        "-o", "UpdateHostKeys=no", "-o", "CheckHostIP=no",
        "-o", "ControlPath=none", "-o", "ConnectTimeout=10", target,
    ]
    deadline = time.monotonic() + 300
    while True:
        result = subprocess.run([*ssh, "readlink -f /run/current-system"], capture_output=True, text=True)
        if result.returncode == 0:
            break
        if time.monotonic() >= deadline:
            raise Failure(f"installed host did not return with the expected SSH key at {target}")
        time.sleep(5)
    if result.stdout.strip() != system:
        raise Failure(f"installed host is running {result.stdout.strip()!r}, expected {system}")
    privileged = "" if target.startswith("root@") else "sudo -n "
    actual_key = run([*ssh, "sh -s"], input=f"{privileged}ssh-keygen -y -P '' -f {shlex.quote(key_path)}\n").split()
    if " ".join(actual_key[:2]) != public:
        raise Failure("installed SSH host key differs from --host-key")
    for mount, info in mounts.items():
        if "noauto" in info["options"]:
            continue
        filesystem = run([*ssh, "sh -s"], input=f"findmnt --mountpoint {shlex.quote(mount)} --noheadings --output FSTYPE\n").strip()
        concrete_type = info["fsType"] not in ("", "auto", "none") and not {"bind", "rbind"}.intersection(info["options"])
        if concrete_type and filesystem != info["fsType"]:
            raise Failure(f"{mount} is mounted as {filesystem!r}, expected {info['fsType']!r}")
    for name, secret in secrets.items():
        actual = run([*ssh, "sh -s"], input=f"{privileged}stat -Lc '%a:%U:%G' -- {shlex.quote(secret['path'])}\n").strip()
        mode, owner, group = actual.split(":", 2)
        if (int(mode, 8), owner, group) != (int(secret["mode"], 8), secret["owner"], secret["group"]):
            raise Failure(f"installed secret {name} has unexpected mode or owner")
    print(f"Installed {system} on {target}; SSH host key, declared mounts and secret metadata match.", file=sys.stderr)


@dataclass(frozen=True)
class InstallPlan:
    host: str
    config: str
    devices: dict[str, str]
    key_path: str
    public: str
    secrets: dict
    mounts: dict
    disk_script: str
    system: str


def install_plan(manifest: Manifest, host: str, host_key: str | None, staging: Path, roots: Path) -> InstallPlan:
    config = install_config_ref(host)
    devices = install_eval(config, "disko.devices.disk", "disks: builtins.mapAttrs (_: disk: disk.device) disks")
    if not isinstance(devices, dict) or not devices:
        raise Failure(f"{host} has no declared Disko disks")
    if install_eval(config, "disko.rootMountPoint") != "/mnt":
        raise Failure(f"{host} needs disko.rootMountPoint = /mnt for this installer")
    keys = install_eval(config, "services.openssh.hostKeys")
    ed25519 = [key["path"] for key in keys if key["type"] == "ed25519"]
    if len(ed25519) != 1 or not ed25519[0].startswith("/etc/") or ".." in Path(ed25519[0]).parts:
        raise Failure(f"{host} needs exactly one Ed25519 SSH host key under /etc")
    key_path = ed25519[0]
    if not install_eval(config, "services.openssh.enable"):
        raise Failure(f"{host} does not enable OpenSSH for post-install identity checks")
    source_key = host_key or f".installer-host-keys/{host}/ssh_host_ed25519_key"
    _, public = stage_install_key(source_key, key_path, staging)
    declared = install_eval(
        config, "", "c: if c ? age && c.age ? rekey then c.age.rekey.hostPubkey else null",
    )
    if declared is not None and " ".join(declared.split()[:2]) != public:
        raise Failure(f"--host-key does not match {host}'s declared SSH host recipient")
    recipients = {
        " ".join(assigned["pubkey"].split()[:2])
        for item in manifest.items.values() for assigned in item.hosts if assigned["name"] == host
    }
    if recipients and recipients != {public}:
        raise Failure(f"--host-key does not match {host}'s declared runtime secret recipient")
    if recipients and key_path not in install_eval(config, "age.identityPaths"):
        raise Failure(f"{key_path} is not a runtime age identity for {host}")
    secrets = install_eval(
        config, "",
        "c: if c ? age then builtins.mapAttrs (_: s: { inherit (s) path mode owner group; }) c.age.secrets else {}",
    )
    mounts = install_eval(config, "fileSystems", "fs: builtins.mapAttrs (_: f: { inherit (f) fsType options; }) fs")
    print(f"Installing {host} from {config}", file=sys.stderr)
    disk_script = build_with_nom(["nix", "build", "--out-link", str(roots / "disko"), "--print-out-paths", f"{config}.system.build.diskoScript"])
    system = build_with_nom(["nix", "build", "--out-link", str(roots / "system"), "--print-out-paths", f"{config}.system.build.toplevel"])
    print(f"Disko: {disk_script}\nSystem: {system}\nInstalled host key: {public}", file=sys.stderr)
    return InstallPlan(host, config, devices, key_path, public, secrets, mounts, disk_script, system)


def require_install_confirmation(assume_yes: bool) -> None:
    if assume_yes or not sys.stdin.isatty():
        raise Failure("install needs a terminal and a typed host/device confirmation; --yes is unavailable")


def install_remote_mode(manifest: Manifest, host: str, target: str, host_key: str | None, verify_target: str,
                        bootstrap: str, kexec_image: str | None, assume_yes: bool) -> int:
    require_install_confirmation(assume_yes)
    if not target.startswith("root@") or not verify_target or "@" not in verify_target:
        raise Failure("specify a root@ installer --target and an explicit user@ --verify-target")
    if bootstrap != "kexec" and kexec_image is not None:
        raise Failure("--kexec-image is only valid with --bootstrap kexec")
    if kexec_image is not None:
        image = Path(kexec_image).resolve()
        if not image.is_file() or not image.is_relative_to("/nix/store") or not str(image).endswith((".tar.gz", ".tar.xz", ".tar.zst", ".tar")):
            raise Failure("--kexec-image must be a tarball at an immutable /nix/store path")
    installer = os.environ.get("NSTDL_INSTALLER")
    if not installer:
        raise Failure("nixos-anywhere is unavailable for this flake")
    if bootstrap == "nixos-installer":
        require_installer(target)
    elif is_installer(target):
        raise Failure(f"{target} is already a NixOS installer; use --bootstrap nixos-installer")
    with tempfile.TemporaryDirectory(prefix="nstdl-install-") as temporary:
        staging = Path(temporary) / "extra"
        roots = Path(temporary) / "roots"
        staging.mkdir()
        roots.mkdir()
        plan = install_plan(manifest, host, host_key, staging, roots)
        before = install_disk_facts(target, plan.devices)
        print("Pinned nixos-anywhere does not verify SSH host keys during bootstrap, transfer or installation.", file=sys.stderr)
        print("An unintended endpoint can receive the private host key and installation data, or have a disk formatted.", file=sys.stderr)
        if bootstrap == "kexec":
            if kexec_image is None:
                print("nixos-anywhere will download its default kexec image; its contents are not pinned by this flake and the target usually needs internet access.", file=sys.stderr)
            if input(f"Kexec {host} at {target}; this interrupts its current OS. Type 'kexec {host}' to proceed: ") != f"kexec {host}":
                raise Failure("kexec not confirmed")
            run([installer, "--store-paths", plan.disk_script, plan.system, "--target-host", target,
                 "--build-on", "local", "--phases", "kexec",
                 *(["--kexec", str(image)] if kexec_image is not None else [])], stdout=None)
            try:
                require_installer(target)
            except Failure as error:
                raise Failure("kexec returned, but the installer is unreachable or unconfirmed; no disk was formatted") from error
            after = install_disk_facts(target, plan.devices)
            if {name: fact[:3] for name, fact in before.items()} != {name: fact[:3] for name, fact in after.items()}:
                print("Disk paths or sizes changed after kexec; review the mapping before continuing.", file=sys.stderr)
        else:
            after = before
        require_unmounted(after)
        require_empty_install_root(target)
        confirm_install(host, plan.devices, f"Format disks on {target}")
        latest = install_disk_facts(target, plan.devices)
        require_unmounted(latest)
        require_empty_install_root(target)
        if latest != after:
            raise Failure("disk facts changed after confirmation; no disk was formatted")
        try:
            run([installer, "--store-paths", plan.disk_script, plan.system, "--target-host", target,
                 "--build-on", "local", "--phases", "disko,install,reboot", "--extra-files", str(staging)], stdout=None)
        except Failure as error:
            raise Failure("remote installation failed; disks may be partly formatted, so inspect the target before retrying") from error
        try:
            verify_install(verify_target, plan.public, plan.system, plan.key_path, plan.secrets, plan.mounts, staging)
        except Failure as error:
            raise Failure(f"installation may have completed, but postboot verification failed: {error}; do not reformat to retry verification") from error
    return 0


def install_local_mode(manifest: Manifest, host: str, host_key: str | None, assume_yes: bool) -> int:
    require_install_confirmation(assume_yes)
    if not sys.platform.startswith("linux") or os.geteuid() != 0:
        raise Failure("install local must run as root on a NixOS installer")
    require_installer(None)
    nixos_install = os.environ.get("NSTDL_NIXOS_INSTALL")
    if not nixos_install:
        raise Failure("pinned nixos-install is unavailable for this flake")
    with tempfile.TemporaryDirectory(prefix="nstdl-install-") as temporary:
        staging = Path(temporary) / "extra"
        roots = Path(temporary) / "roots"
        staging.mkdir()
        roots.mkdir()
        plan = install_plan(manifest, host, host_key, staging, roots)
        before = install_disk_facts(None, plan.devices)
        require_unmounted(before)
        require_empty_install_root(None)
        confirm_install(host, plan.devices, "Format disks on this machine")
        latest = install_disk_facts(None, plan.devices)
        require_unmounted(latest)
        require_empty_install_root(None)
        if latest != before:
            raise Failure("disk facts changed after confirmation; no disk was formatted")
        try:
            run([plan.disk_script], stdout=None, env={**os.environ, "DISKO_SKIP_SWAP": "1"})
        except Failure as error:
            raise Failure("Disko failed; disks may be partly formatted, so inspect them before retrying") from error
        try:
            install_shell(None, "findmnt --mountpoint /mnt >/dev/null\n")
        except Failure as error:
            raise Failure("Disko returned without mounting /mnt; inspect the formatted disks before retrying") from error
        destination = Path("/mnt") / plan.key_path.lstrip("/")
        try:
            destination.parent.mkdir(parents=True, exist_ok=True)
            descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as copy, (staging / plan.key_path.lstrip("/")).open("rb") as source:
                shutil.copyfileobj(source, copy)
            destination.with_name(destination.name + ".pub").write_text(plan.public + "\n")
        except OSError as error:
            raise Failure(f"cannot place the host key in /mnt after formatting: {error.strerror}") from error
        try:
            run([nixos_install, "--system", plan.system, "--root", "/mnt", "--no-channel-copy", "--no-root-password"], stdout=None)
        except Failure as error:
            raise Failure("NixOS installation failed after formatting; inspect /mnt before retrying") from error
        print(f"Installed {plan.system} on {', '.join(plan.devices.values())}; boot has not been verified.", file=sys.stderr)
    return 0


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

    diff_command = nouns.add_parser("diff", help="build a host and preview changes without activation")
    diff_command.add_argument("--diff-files", action="store_true", help="also print a unified diff of /etc")
    diff_command.add_argument("--remote-build", action="store_true", help="build on the target host")
    diff_command.add_argument("host", metavar="HOST", help=", ".join(sorted(manifest.deploy_nodes)) or "no deployable hosts")

    deploy = nouns.add_parser(
        "deploy",
        help="build a host, show what changes, and activate it with deploy-rs",
        description="Builds the host's system, copies it to the host, shows what changes against the "
        "running system — packages, rebuilt store paths, and the units the switch would touch — and asks "
        "before deploy-rs activates it (--yes skips the question).",
    )
    deploy.add_argument(
        "--diff-files",
        action="store_true",
        help="also print a unified diff of the host's /etc, generated units included",
    )
    deploy.add_argument(
        "--no-rollback",
        action="store_true",
        help="keep the new generation even if activation fails or the host stops answering; "
        "for a failure that a reboot clears",
    )
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
        help="deploy-rs options; target, profile, SSH and extra build overrides are refused",
    )

    installer = nouns.add_parser("install", help="install a declared NixOS host using Disko")
    modes = installer.add_subparsers(dest="install_mode", required=True, metavar="LOCATION")
    remote = modes.add_parser("remote", help="install over SSH from a controller")
    remote.add_argument("--target", required=True, help="root@ bootstrap SSH endpoint")
    remote.add_argument("--host-key", help="private Ed25519 key; defaults to .installer-host-keys/HOST/ssh_host_ed25519_key")
    remote.add_argument("--verify-target", required=True, help="user@ endpoint to inspect after reboot")
    remote.add_argument("--bootstrap", required=True, choices=("kexec", "nixos-installer"), help="current state of the remote target")
    remote.add_argument("--kexec-image", help="optional immutable Nix store kexec tarball; otherwise nixos-anywhere downloads its default")
    remote.add_argument("host", metavar="HOST", help="name in nixosConfigurations")
    local = modes.add_parser("local", help="install from the NixOS installer console")
    local.add_argument("--host-key", help="private Ed25519 key; defaults to .installer-host-keys/HOST/ssh_host_ed25519_key")
    local.add_argument("host", metavar="HOST", help="name in nixosConfigurations")
    return root


def main(argv: list[str]) -> int:
    manifest = Manifest(os.environ["NSTDL_MANIFEST"])
    args = parser(manifest).parse_args(argv)
    try:
        if not Path("flake.nix").is_file():
            raise Failure("run from the flake root (the ./nstdl wrapper does this)")
        if args.noun == "deploy":
            return deploy(manifest, args.host, args.rest, args.no_rollback, args.diff_files, args.yes)
        if args.noun == "diff":
            return diff(manifest, args.host, args.remote_build, args.diff_files)
        if args.noun == "install":
            if args.install_mode == "remote":
                return install_remote_mode(manifest, args.host, args.target, args.host_key,
                                           args.verify_target, args.bootstrap, args.kexec_image, args.yes)
            return install_local_mode(manifest, args.host, args.host_key, args.yes)
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
