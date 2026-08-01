#!/usr/bin/env python3
"""Run a SwiftPM command and reject compiler warnings originating in Fovea-owned sources."""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OWNED_PREFIXES = ("Sources/", "Tests/", "Tools/", "Examples/")
WARNING = re.compile(r"(?:^|\s)warning:", re.IGNORECASE)


def is_owned_warning(line: str) -> bool:
    if WARNING.search(line) is None:
        return False
    normalized = line.replace("\\", "/")
    root = ROOT.as_posix().rstrip("/") + "/"
    if root in normalized:
        suffix = normalized.split(root, 1)[1]
        return suffix.startswith(OWNED_PREFIXES)
    stripped = normalized.lstrip("./")
    return stripped.startswith(OWNED_PREFIXES)


def main() -> int:
    if not sys.argv[1:]:
        print("usage: run-swift-strict.py test|build [SwiftPM arguments ...]", file=sys.stderr)
        return 64
    environment = os.environ.copy()
    completed = subprocess.run(
        ["xcrun", "swift", *sys.argv[1:]],
        cwd=ROOT,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    sys.stdout.write(completed.stdout)
    if completed.returncode != 0:
        return completed.returncode
    warnings = [line for line in completed.stdout.splitlines() if is_owned_warning(line)]
    if warnings:
        print("Fovea-owned compiler warnings are forbidden:", file=sys.stderr)
        for line in warnings:
            print(f"- {line}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
