"""Tests for the host's nstdl dispatcher against a generated command table."""

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("nstdl_host.py")
sys.path.insert(0, str(SCRIPT.parent))
import nstdl_host  # noqa: E402


class DispatcherTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        program = root / "echo-arguments"
        program.write_text('#!/bin/sh\nprintf "%s|" "$0" "$@"\nexit 3\n')
        program.chmod(program.stat().st_mode | stat.S_IXUSR)
        self.program = str(program)
        self.manifest = {
            "host": "app-01",
            "commands": {
                "postgresql": {"restore": {"program": self.program, "description": "SET [--yes]  restore a backup set"}},
                "app": {"reindex": {"program": self.program, "description": "rebuild the search index"}},
            },
        }
        self.table = root / "commands.json"
        self.table.write_text(json.dumps(self.manifest))

    def tearDown(self):
        self.directory.cleanup()

    def nstdl(self, *argv):
        environment = {**os.environ, "NSTDL_COMMANDS": str(self.table)}
        return subprocess.run([sys.executable, str(SCRIPT), *argv], env=environment, capture_output=True, text=True)

    def test_listing_is_sorted_and_aligned(self):
        self.assertEqual(
            nstdl_host.listing(self.manifest).splitlines(),
            [
                "Commands on app-01:",
                "  app reindex         rebuild the search index",
                "  postgresql restore  SET [--yes]  restore a backup set",
                nstdl_host.REPOSITORY_HINT,
            ],
        )

    def test_no_commands(self):
        self.assertEqual(nstdl_host.listing({"host": "ws", "commands": {}}).splitlines()[0], "No nstdl commands on ws.")

    def test_no_arguments_and_help_list(self):
        for argv in ([], ["help"], ["--help"], ["-h"]):
            result = self.nstdl(*argv)
            self.assertEqual(result.returncode, 0)
            self.assertIn("postgresql restore", result.stdout)

    def test_command_replaces_the_process_with_its_arguments_and_exit_code(self):
        result = self.nstdl("postgresql", "restore", "/sets/a b", "--yes")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(result.stdout, f"{self.program}|/sets/a b|--yes|")

    def test_unknown_commands_list_and_point_to_the_repository_tool(self):
        for argv in (["deploy", "app-01"], ["postgresql"], ["postgresql", "backup"]):
            result = self.nstdl(*argv)
            self.assertEqual(result.returncode, 2)
            self.assertIn(f"unknown command '{' '.join(argv[:2])}'", result.stderr)
            self.assertIn("./nstdl", result.stderr)
            self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
