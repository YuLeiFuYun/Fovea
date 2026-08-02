#!/usr/bin/env python3
"""Lint Swift owned by Fovea without rewriting byte-locked component mirrors."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMPONENT_SOURCE_DIRECTORIES = {
    "AkashicCore",
    "AkashicDisk",
    "AkashicMemory",
    "ImageCraftCore",
    "ImageCraftImageIO",
}


def owned_swift_files() -> list[Path]:
    files: list[Path] = []
    sources = ROOT / "Sources"
    for directory in sorted(sources.iterdir()):
        if not directory.is_dir() or directory.name in COMPONENT_SOURCE_DIRECTORIES:
            continue
        files.extend(sorted(directory.rglob("*.swift")))
    for relative in ("Tests", "Tools", "Examples"):
        files.extend(sorted((ROOT / relative).rglob("*.swift")))
    files.append(ROOT / "Package.swift")
    return files


def main() -> int:
    files = owned_swift_files()
    if not files:
        print("Fovea Swift format gate found no owned files", file=sys.stderr)
        return 1
    command = [
        "xcrun",
        "swift-format",
        "lint",
        "--configuration",
        str(ROOT / ".swift-format"),
        "--strict",
        *[str(path) for path in files],
    ]
    completed = subprocess.run(command, cwd=ROOT, env=os.environ.copy(), check=False)
    if completed.returncode != 0:
        return completed.returncode
    print(
        "Fovea Swift format passed: "
        f"files={len(files)} excludedComponentDirectories={len(COMPONENT_SOURCE_DIRECTORIES)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
