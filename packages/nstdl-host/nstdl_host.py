"""The host's nstdl: operator commands registered under nstdl.commands.

The command table is JSON from the NixOS configuration, named by
NSTDL_COMMANDS: {"host": ..., "commands": {area: {action: {program, description}}}}."""

import json
import os
import sys
from pathlib import Path

REPOSITORY_HINT = "Repository commands (deploy, secret, ...) run as ./nstdl in your config repository."


def listing(manifest: dict) -> str:
    host = manifest["host"]
    entries = [(f"{area} {action}", command["description"]) for area, actions in sorted(manifest["commands"].items()) for action, command in sorted(actions.items())]
    if not entries:
        return f"No nstdl commands on {host}.\n{REPOSITORY_HINT}"
    width = max(len(name) for name, _ in entries)
    lines = [f"Commands on {host}:"] + [f"  {name.ljust(width)}  {description}" for name, description in entries]
    return "\n".join(lines + [REPOSITORY_HINT])


def resolve(manifest: dict, argv: list[str]) -> tuple[str, list[str]] | None:
    if len(argv) < 2:
        return None
    command = manifest["commands"].get(argv[0], {}).get(argv[1])
    return (command["program"], argv[2:]) if command else None


def main(argv: list[str]) -> int:
    manifest = json.loads(Path(os.environ["NSTDL_COMMANDS"]).read_text())
    if not argv or argv[0] in ("help", "-h", "--help"):
        print(listing(manifest))
        return 0
    found = resolve(manifest, argv)
    if found is None:
        print(f"nstdl: unknown command '{' '.join(argv[:2])}'", file=sys.stderr)
        print(listing(manifest), file=sys.stderr)
        return 2
    program, arguments = found
    # exec, not a child: the command owns the terminal, signals and exit code.
    os.execv(program, [program, *arguments])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
