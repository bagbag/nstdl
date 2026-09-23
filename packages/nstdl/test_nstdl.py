"""Tests for nstdl secret, against real rage/mkpasswd/xkcdpass and a throwaway
identity in a temporary git repository. agenix is replaced by a stub that
records its arguments."""

import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

# The tests import nstdl.py from the source tree; keep __pycache__ out of it.
sys.dont_write_bytecode = True

SCRIPT = Path(__file__).with_name("nstdl.py")
sys.path.insert(0, str(SCRIPT.parent))
import nstdl  # noqa: E402


class SecretCommandTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / "flake.nix").write_text("{ }\n")

        identity = self.root / "identity.txt"
        subprocess.run(["rage-keygen", "-o", str(identity)], check=True, stderr=subprocess.DEVNULL)
        self.identity = str(identity)
        recipient = subprocess.run(
            ["rage-keygen", "-y", str(identity)], check=True, capture_output=True, text=True
        ).stdout.strip()

        self.agenix_log = self.root / "agenix.log"
        agenix = self.root / "agenix-stub"
        # Like agenix-rekey, fails while a host-granted secret has no file.
        agenix.write_text(
            f'#!/bin/sh\nfor f in secrets/key.age secrets/admin-password-hash.age secrets/npm-token.age; '
            f'do test -f "$f" || exit 1; done\necho "$*" >> {self.agenix_log}\n'
        )
        agenix.chmod(0o755)

        def item(file, generator=None, rotate=False, hosts=()):
            return {"file": file, "rotate": rotate, "generator": generator, "hosts": list(hosts)}

        host = {"name": "server", "pubkey": "ssh-ed25519 AAAAhost", "rekeyedDir": "secrets/rekeyed/server"}
        random = {"type": "random", "format": "hex", "bytes": 32, "length": None, "words": 6, "from": None}
        manifest = {
            "recipients": [recipient],
            "identities": [self.identity, "~/does-not-exist"],
            "items": {
                "key": item("secrets/key.age", random, hosts=[host]),
                "token": item("secrets/token.age", {**random, "bytes": 16, "format": "base64"}, rotate=True),
                "admin-password": item("secrets/admin-password.age", {**random, "type": "passphrase", "words": 4}),
                "admin-password-hash": item(
                    "secrets/admin-password-hash.age",
                    {**random, "type": "password-hash", "from": "admin-password"},
                    hosts=[host],
                ),
                "npm-token": item("secrets/npm-token.age", hosts=[host]),
                "api-token": item("secrets/api-token.age", rotate=True),
                "chosen-password-hash": item(
                    "secrets/chosen-password-hash.age", {**random, "type": "password-hash"}
                ),
                "ext-password": item("secrets/ext-password.age", rotate=True),
                "ext-password-hash": item(
                    "secrets/ext-password-hash.age", {**random, "type": "password-hash", "from": "ext-password"}
                ),
            },
            "deploy": {"nodes": ["server"]},
        }
        self.manifest = self.root / "manifest.json"
        self.manifest.write_text(json.dumps(manifest))
        self.environment = {**os.environ, "NSTDL_MANIFEST": str(self.manifest), "NSTDL_AGENIX": str(agenix)}

    def assert_hash_of(self, name, password):
        stored = self.decrypt(name)
        self.assertTrue(stored.startswith("$y$"))
        recomputed = subprocess.run(
            ["mkpasswd", f"--salt={stored.rsplit('$', 1)[0]}", "--stdin"],
            input=password,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        self.assertEqual(recomputed, stored)

    def tearDown(self):
        self.directory.cleanup()

    def nstdl(self, *args, input=None):
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            cwd=self.root,
            env=self.environment,
            input=input,
            capture_output=True,
            text=True,
        )

    def decrypt(self, name):
        return subprocess.run(
            ["rage", "-d", "-i", self.identity, str(self.root / "secrets" / f"{name}.age")],
            check=True,
            capture_output=True,
            text=True,
        ).stdout

    def file_bytes(self, name):
        return (self.root / "secrets" / f"{name}.age").read_bytes()

    def test_sync_creates_generated_values_and_rekeys(self):
        result = self.nstdl("--yes", "secret", "sync")
        self.assertEqual(result.returncode, 0, result.stderr)

        key = self.decrypt("key")
        self.assertRegex(key, r"^[0-9a-f]{64}$")
        self.assertEqual(len(base64.b64decode(self.decrypt("token"), validate=True)), 16)
        passphrase = self.decrypt("admin-password")
        self.assertEqual(len(passphrase.split(" ")), 4)

        self.assert_hash_of("admin-password-hash", passphrase)

        self.assertFalse((self.root / "secrets/npm-token.age").exists())
        self.assertFalse((self.root / "secrets/chosen-password-hash.age").exists())
        self.assertIn("npm-token, api-token, chosen-password-hash, ext-password", result.stderr)
        # Rekeying now would fail on the host-granted npm-token.
        self.assertIn("Rekey deferred until these have a value: npm-token", result.stderr)
        self.assertFalse(self.agenix_log.exists())

        done = self.nstdl("--yes", "secret", "set", "npm-token", input="npm_abc\n")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(self.agenix_log.read_text(), "rekey -a\n")

        tracked = subprocess.run(
            ["git", "ls-files"], cwd=self.root, check=True, capture_output=True, text=True
        ).stdout.split()
        self.assertIn("secrets/key.age", tracked)
        self.assertEqual([path for path in os.listdir(self.root / "secrets") if path.startswith(".")], [])

    def test_sync_never_replaces_existing_values(self):
        self.nstdl("--yes", "secret", "sync")
        before = {name: self.file_bytes(name) for name in ("key", "token", "admin-password", "admin-password-hash")}
        result = self.nstdl("--yes", "secret", "sync")
        self.assertEqual(result.returncode, 0, result.stderr)
        for name, content in before.items():
            self.assertEqual(self.file_bytes(name), content, name)

    def test_sync_refuses_a_derived_value_whose_source_it_would_create(self):
        self.nstdl("--yes", "secret", "sync")
        hash_before = self.file_bytes("admin-password-hash")
        (self.root / "secrets/admin-password.age").unlink()

        result = self.nstdl("--yes", "secret", "sync")
        self.assertEqual(result.returncode, 1)
        self.assertIn("'admin-password-hash' exists but its source 'admin-password' does not", result.stderr)
        self.assertFalse((self.root / "secrets/admin-password.age").exists())
        self.assertEqual(self.file_bytes("admin-password-hash"), hash_before)

    def test_rotate_respects_the_rotate_flag(self):
        self.nstdl("--yes", "secret", "sync")
        key, token = self.file_bytes("key"), self.file_bytes("token")

        refused = self.nstdl("--yes", "secret", "rotate", "key")
        self.assertEqual(refused.returncode, 1)
        self.assertIn("does not allow rotation", refused.stderr)
        self.assertEqual(self.file_bytes("key"), key)

        derived = self.nstdl("--yes", "secret", "rotate", "admin-password-hash")
        self.assertEqual(derived.returncode, 1)
        self.assertIn("rotate its source 'admin-password'", derived.stderr)

        rotated = self.nstdl("--yes", "secret", "rotate", "token")
        self.assertEqual(rotated.returncode, 0, rotated.stderr)
        self.assertNotEqual(self.file_bytes("token"), token)

    def test_hash_of_an_entered_source_waits_for_set(self):
        status = self.nstdl("secret", "status")
        self.assertRegex(status.stdout, r"ext-password-hash\s+missing: run set ext-password")

        synced = self.nstdl("--yes", "secret", "sync")
        self.assertEqual(synced.returncode, 0, synced.stderr)
        self.assertIn("ext-password-hash (set ext-password)", synced.stderr)
        self.assertFalse((self.root / "secrets/ext-password-hash.age").exists())

        self.assertEqual(self.nstdl("--yes", "secret", "set", "ext-password", input="one\n").returncode, 0)
        self.assert_hash_of("ext-password-hash", "one")

    def test_rotate_derives_hashes_from_the_new_value_without_an_identity(self):
        self.nstdl("--yes", "secret", "set", "ext-password", input="one\n")
        hidden = self.root / "identity.hidden"
        os.rename(self.identity, hidden)
        try:
            rotated = self.nstdl("--yes", "secret", "rotate", "ext-password", input="two\n")
        finally:
            os.rename(hidden, self.identity)
        self.assertEqual(rotated.returncode, 0, rotated.stderr)
        self.assertEqual(self.decrypt("ext-password"), "two")
        self.assert_hash_of("ext-password-hash", "two")

    def test_a_failed_hash_leaves_source_and_hash_unchanged(self):
        self.nstdl("--yes", "secret", "set", "ext-password", input="one\n")
        before = {name: self.file_bytes(name) for name in ("ext-password", "ext-password-hash")}
        stubs = self.root / "failing"
        stubs.mkdir()
        (stubs / "mkpasswd").write_text("#!/bin/sh\nexit 1\n")
        (stubs / "mkpasswd").chmod(0o755)
        self.environment["PATH"] = f"{stubs}:{os.environ['PATH']}"
        rotated = self.nstdl("--yes", "secret", "rotate", "ext-password", input="two\n")
        self.assertEqual(rotated.returncode, 1)
        for name, content in before.items():
            self.assertEqual(self.file_bytes(name), content, name)

    def test_set_replace_corrects_an_entered_value(self):
        self.nstdl("--yes", "secret", "set", "npm-token", input="npm_typo\n")
        fixed = self.nstdl("--yes", "secret", "set", "--replace", "npm-token", input="npm_abc\n")
        self.assertEqual(fixed.returncode, 0, fixed.stderr)
        self.assertEqual(self.decrypt("npm-token"), "npm_abc")

        self.nstdl("--yes", "secret", "set", "ext-password", input="typo\n")
        self.nstdl("--yes", "secret", "set", "--replace", "ext-password", input="right\n")
        self.assert_hash_of("ext-password-hash", "right")

        self.nstdl("--yes", "secret", "sync")
        generated = self.nstdl("--yes", "secret", "set", "--replace", "key", input="x\n")
        self.assertEqual(generated.returncode, 1)
        self.assertIn("is generated", generated.stderr)

    def test_set_only_creates(self):
        created = self.nstdl("--yes", "secret", "set", "npm-token", input="npm_abc\n")
        self.assertEqual(created.returncode, 0, created.stderr)
        self.assertEqual(self.decrypt("npm-token"), "npm_abc")

        refused = self.nstdl("--yes", "secret", "set", "npm-token", input="npm_other\n")
        self.assertEqual(refused.returncode, 1)
        self.assertEqual(self.decrypt("npm-token"), "npm_abc")

        # Without --replace, set never replaces, even where rotate may.
        self.nstdl("--yes", "secret", "set", "api-token", input="first\n")
        again = self.nstdl("--yes", "secret", "set", "api-token", input="second\n")
        self.assertEqual(again.returncode, 1)
        self.assertIn("set --replace", again.stderr)
        self.assertEqual(self.decrypt("api-token"), "first")

        generated = self.nstdl("--yes", "secret", "set", "key", input="x\n")
        self.assertEqual(generated.returncode, 1)
        self.assertIn("is generated", generated.stderr)

    def test_rotate_replaces_an_entered_value(self):
        self.nstdl("--yes", "secret", "set", "npm-token", input="npm_abc\n")
        refused = self.nstdl("--yes", "secret", "rotate", "npm-token", input="npm_new\n")
        self.assertEqual(refused.returncode, 1)
        self.assertIn("does not allow rotation", refused.stderr)

        self.nstdl("--yes", "secret", "set", "api-token", input="first\n")
        rotated = self.nstdl("--yes", "secret", "rotate", "api-token", input="second\n")
        self.assertEqual(rotated.returncode, 0, rotated.stderr)
        self.assertEqual(self.decrypt("api-token"), "second")

    def edit(self, name, editor_script):
        """Runs `edit` in-process as if from a terminal, with a stub editor."""
        editor = self.root / "bin" / "micro"
        editor.parent.mkdir(exist_ok=True)
        # The file comes last, after the hardening options.
        editor.write_text(f"#!/bin/sh\necho \"$@\" > {self.root}/editor-args\nfor file; do :; done\n{editor_script}\n")
        editor.chmod(0o755)
        plaintext = self.root / "plaintext"
        plaintext.mkdir(exist_ok=True)
        previous = os.getcwd()
        os.chdir(self.root)
        try:
            commands = nstdl.Secrets(nstdl.Manifest(str(self.manifest)), self.environment["NSTDL_AGENIX"], assume_yes=False)
            with mock.patch.dict(os.environ, {"EDITOR": str(editor), "VISUAL": ""}), \
                    mock.patch("sys.stdin.isatty", return_value=True), \
                    mock.patch.object(nstdl, "plaintext_directory", return_value=str(plaintext)):
                commands.edit(commands.manifest.items[name])
        finally:
            os.chdir(previous)
        self.assertEqual(list(plaintext.iterdir()), [], "plaintext left behind")
        return (self.root / "editor-args").read_text()

    def test_edit_round_trips_the_value_exactly(self):
        self.nstdl("--yes", "secret", "sync")
        self.nstdl("--yes", "secret", "set", "npm-token", input="npm_abc\n")
        self.nstdl("--yes", "secret", "set", "api-token", input="first\n")
        self.agenix_log.unlink(missing_ok=True)
        args = self.edit("api-token", 'test "$(cat "$file")" = first || exit 1; printf second > "$file"')
        self.assertEqual(self.decrypt("api-token"), "second")
        self.assertIn("-backup false -eofnewline false", args)
        self.assertEqual(self.agenix_log.read_text(), "rekey -a\n")

    def test_edit_drops_a_final_newline_an_editor_appends(self):
        self.nstdl("--yes", "secret", "set", "api-token", input="first\n")
        self.edit("api-token", 'printf "second\\n" > "$file"')
        self.assertEqual(self.decrypt("api-token"), "second")

    def test_edit_without_changes_writes_nothing(self):
        self.nstdl("--yes", "secret", "set", "api-token", input="first\n")
        before = self.file_bytes("api-token")
        self.agenix_log.unlink(missing_ok=True)
        self.edit("api-token", "true")
        self.assertEqual(self.file_bytes("api-token"), before)
        self.assertFalse(self.agenix_log.exists())

    def test_edit_refuses_values_that_must_not_change(self):
        self.nstdl("--yes", "secret", "set", "npm-token", input="npm_abc\n")
        with self.assertRaisesRegex(nstdl.Failure, "does not allow replacing"):
            self.edit("npm-token", "true")
        piped = self.nstdl("--yes", "secret", "edit", "api-token")
        self.assertEqual(piped.returncode, 1)
        self.assertIn("edit needs a terminal", piped.stderr)

    def test_changes_need_a_terminal_or_yes(self):
        result = self.nstdl("secret", "sync", input="")
        self.assertEqual(result.returncode, 1)
        self.assertIn("--yes", result.stderr)
        self.assertFalse((self.root / "secrets").exists())

    def test_status_reports_missing_values_and_pending_rekeys(self):
        missing = self.nstdl("secret", "status", "--check")
        self.assertEqual(missing.returncode, 3)
        self.assertRegex(missing.stdout, r"key\s+missing: run sync")
        self.assertRegex(missing.stdout, r"npm-token\s+missing: run set")

        self.nstdl("--yes", "secret", "sync")
        pending = self.nstdl("secret", "status")
        self.assertEqual(pending.returncode, 0)
        self.assertRegex(pending.stdout, r"key\s+not rekeyed: run sync\s+server \(pending\)")

    def test_unknown_item_is_a_usage_error(self):
        result = self.nstdl("secret", "view", "nope")
        self.assertEqual(result.returncode, 2)


class RotateConfirmationTest(unittest.TestCase):
    """The typed-name confirmation, which only an interactive session sees."""

    def setUp(self):
        self.nstdl = nstdl
        self.directory = tempfile.TemporaryDirectory()
        self.file = Path(self.directory.name) / "token.age"
        self.file.write_bytes(b"existing")
        manifest = Path(self.directory.name) / "manifest.json"
        manifest.write_text(json.dumps({"recipients": [], "identities": [], "items": {}, "deploy": {"nodes": []}}))
        self.secrets = nstdl.Secrets(nstdl.Manifest(str(manifest)), "true", assume_yes=False)
        self.item = nstdl.Item("token", self.file, rotate=True, generator=None, hosts=[])

    def tearDown(self):
        self.directory.cleanup()

    def test_a_wrong_name_cancels_before_anything_is_asked_or_written(self):
        for command in (self.secrets.rotate, lambda item: self.secrets.set(item, replace=True)):
            with mock.patch("sys.stdin.isatty", return_value=True), \
                    mock.patch("builtins.input", return_value="tokn"), \
                    mock.patch("getpass.getpass") as getpass:
                with self.assertRaisesRegex(self.nstdl.Failure, "not confirmed"):
                    command(self.item)
            getpass.assert_not_called()
            self.assertEqual(self.file.read_bytes(), b"existing")


class EditorHardeningTest(unittest.TestCase):
    def test_vi_resolving_to_vim_is_hardened(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            vim = root / "vim"
            vim.write_text(f'#!/bin/sh\necho "$@" > {root}/args\n')
            vim.chmod(0o755)
            (root / "vi").symlink_to(vim)
            with mock.patch.dict(os.environ, {"EDITOR": str(root / "vi"), "VISUAL": ""}), \
                    mock.patch.object(nstdl, "plaintext_directory", return_value=directory):
                nstdl.edit_in_editor("x", "value")
            self.assertTrue((root / "args").read_text().startswith("-n -i NONE --cmd "))

    def test_vim_resolving_to_a_variant_stays_hardened(self):
        # Debian: vim -> /etc/alternatives/vim -> vim.basic.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            variant = root / "vim.basic"
            variant.write_text(f'#!/bin/sh\necho "$@" > {root}/args\n')
            variant.chmod(0o755)
            (root / "vim").symlink_to(variant)
            with mock.patch.dict(os.environ, {"EDITOR": str(root / "vim"), "VISUAL": ""}), \
                    mock.patch.object(nstdl, "plaintext_directory", return_value=directory):
                nstdl.edit_in_editor("x", "value")
            self.assertTrue((root / "args").read_text().startswith("-n -i NONE --cmd "))


class RandomValueTest(unittest.TestCase):
    def setUp(self):
        self.nstdl = nstdl

    def test_bytes_encodings_decode_to_exactly_those_bytes(self):
        self.assertEqual(len(bytes.fromhex(self.nstdl.random_value("hex", 32, None))), 32)
        self.assertEqual(len(base64.b64decode(self.nstdl.random_value("base64", 32, None), validate=True)), 32)
        self.assertEqual(len(base64.urlsafe_b64decode(self.nstdl.random_value("base64url", 32, None))), 32)

    def test_character_formats_draw_length_characters(self):
        self.assertRegex(self.nstdl.random_value("alphanumeric-lowercase", None, 25), r"^[a-z0-9]{25}$")
        self.assertRegex(self.nstdl.random_value("alphanumeric", None, 40), r"^[A-Za-z0-9]{40}$")


class StoreTest(unittest.TestCase):
    """Publishing semantics, exercised directly."""

    def setUp(self):
        self.nstdl = nstdl
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        identity = self.root / "identity.txt"
        subprocess.run(["rage-keygen", "-o", str(identity)], check=True, stderr=subprocess.DEVNULL)
        recipient = subprocess.run(
            ["rage-keygen", "-y", str(identity)], check=True, capture_output=True, text=True
        ).stdout.strip()
        manifest = self.root / "manifest.json"
        manifest.write_text(json.dumps({"recipients": [recipient], "identities": [str(identity)], "items": {}, "deploy": {"nodes": []}}))
        self.secrets = nstdl.Secrets(nstdl.Manifest(str(manifest)), "true", assume_yes=True)
        self.item = nstdl.Item("x", self.root / "x.age", rotate=False, generator=None, hosts=[])

    def tearDown(self):
        self.directory.cleanup()

    def test_empty_values_are_refused(self):
        with self.assertRaises(self.nstdl.Failure):
            self.secrets.store(self.item, "", replace=False)
        self.assertFalse(self.item.file.exists())

    def test_create_never_overwrites(self):
        self.item.file.write_bytes(b"existing")
        with self.assertRaises(self.nstdl.Failure):
            self.secrets.store(self.item, "value", replace=False)
        self.assertEqual(self.item.file.read_bytes(), b"existing")
        self.assertEqual(sorted(os.listdir(self.root)), ["identity.txt", "manifest.json", "x.age"])


class DeployArgvTest(unittest.TestCase):
    """Host validation. Nothing here exercises a deployment: the sandbox this
    suite runs in has no host, no network and no store to activate."""

    def setUp(self):
        self.nstdl = nstdl

    def test_host_becomes_a_flake_reference(self):
        self.assertEqual(
            self.nstdl.deploy_argv(["server"], "server", []),
            [".#server"],
        )

    def test_unknown_host_names_the_deployable_ones(self):
        with self.assertRaises(self.nstdl.Failure) as failure:
            self.nstdl.deploy_argv(["beta", "alpha"], "gamma", [])
        self.assertIn("alpha, beta", str(failure.exception))

    def test_a_flake_without_deployable_hosts_says_so(self):
        with self.assertRaises(self.nstdl.Failure) as failure:
            self.nstdl.deploy_argv([], "server", [])
        self.assertIn("deployment.enable", str(failure.exception))


class DeployCommandTest(unittest.TestCase):
    """The command line as typed, through argparse, into a stub deploy-rs that
    records its argv — the layer where a `--` is or is not consumed."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        (self.root / "flake.nix").write_text("{ }\n")
        manifest = self.root / "manifest.json"
        manifest.write_text(json.dumps({"recipients": [], "identities": [], "items": {}, "deploy": {"nodes": ["server"]}}))
        self.log = self.root / "deploy.log"
        stub = self.root / "deploy-stub"
        stub.write_text(f'#!/bin/sh\nprintf "%s\\n" "$@" > {self.log}\n')
        stub.chmod(0o755)
        self.environment = {**os.environ, "NSTDL_MANIFEST": str(manifest), "NSTDL_DEPLOY": str(stub)}

    def tearDown(self):
        self.directory.cleanup()

    def deploy(self, *args):
        run = subprocess.run(
            [sys.executable, str(SCRIPT), "deploy", *args],
            cwd=self.root,
            env=self.environment,
            capture_output=True,
            text=True,
        )
        self.assertEqual(run.returncode, 0, run.stderr)
        return self.log.read_text().splitlines()

    def test_arguments_after_the_host_pass_through(self):
        self.assertEqual(self.deploy("server", "--dry-activate", "-s"), [".#server", "--dry-activate", "-s"])

    def test_the_separator_is_optional(self):
        self.assertEqual(self.deploy("server", "--", "--dry-activate"), [".#server", "--dry-activate"])

    def test_deploy_rs_own_separator_survives(self):
        # deploy-rs hands everything after its `--` to `nix build`.
        self.assertEqual(self.deploy("server", "--", "--", "--impure"), [".#server", "--", "--impure"])


if __name__ == "__main__":
    unittest.main()
