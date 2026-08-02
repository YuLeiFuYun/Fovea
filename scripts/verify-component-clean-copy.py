#!/usr/bin/env python3
"""Resolve public exact component pins and run Fovea tests from a clean source copy."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PINS = ROOT / "docs/project-memory/component-pins.json"
ARTIFACT = ROOT / ".artifacts/external-components/clean-copy.json"
LOG = ROOT / ".artifacts/external-components/swift-test.log"
COPY_PATHS = ("Sources", "Tests", "Tools", "Examples/FoveaGalleryDemo")
EXPECTED_TEST_COUNT = 478


def run(command: list[str], *, cwd: Path, env: dict[str, str], timeout: int = 900) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
        timeout=timeout,
    )


def file_digest(root: Path) -> str:
    rows: list[bytes] = []
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        if any(part in {".build", ".swiftpm", ".artifacts"} for part in path.parts):
            continue
        relative = path.relative_to(root).as_posix()
        rows.append(relative.encode() + b"\0" + hashlib.sha256(path.read_bytes()).hexdigest().encode() + b"\n")
    return hashlib.sha256(b"".join(rows)).hexdigest()


def expected_pins() -> dict[str, tuple[str, str]]:
    document = json.loads(PINS.read_text())
    return {
        name.lower(): (component["repositoryURL"], component["revision"])
        for name, component in document["components"].items()
    }


def validate_resolved(path: Path, expected: dict[str, tuple[str, str]]) -> None:
    document = json.loads(path.read_text())
    observed = {
        pin["identity"]: (pin["location"], pin["state"]["revision"])
        for pin in document.get("pins", [])
    }
    if observed != expected:
        raise RuntimeError(f"clean-copy resolution drifted: expected={expected!r} observed={observed!r}")


def copy_source(destination: Path) -> None:
    for relative in ("Package.swift", "Package.resolved"):
        shutil.copy2(ROOT / relative, destination / relative)
    for relative in COPY_PATHS:
        shutil.copytree(
            ROOT / relative,
            destination / relative,
            ignore=shutil.ignore_patterns(".DS_Store", ".build", ".swiftpm", ".artifacts", "__pycache__", "*.pyc"),
        )


def main() -> int:
    env = os.environ.copy()
    selection = run([str(ROOT / "scripts/select-xcode.sh")], cwd=ROOT, env=env, timeout=30)
    if selection.returncode != 0:
        print(selection.stdout)
        return selection.returncode
    env["DEVELOPER_DIR"] = selection.stdout.strip()
    expected = expected_pins()
    try:
        with tempfile.TemporaryDirectory(prefix="fovea-component-clean-copy-") as directory:
            copy = Path(directory) / "Fovea"
            copy.mkdir()
            copy_source(copy)
            source_digest = file_digest(copy)
            resolve = run(["xcrun", "swift", "package", "resolve"], cwd=copy, env=env)
            if resolve.returncode != 0:
                raise RuntimeError("clean-copy dependency resolution failed:\n" + resolve.stdout)
            validate_resolved(copy / "Package.resolved", expected)
            test = run(["xcrun", "swift", "test"], cwd=copy, env=env)
            LOG.parent.mkdir(parents=True, exist_ok=True)
            LOG.write_text(test.stdout)
            if test.returncode != 0:
                raise RuntimeError("clean-copy tests failed; see " + str(LOG.relative_to(ROOT)))
            owned_roots = tuple(str(copy / prefix) for prefix in ("Sources", "Tests", "Tools", "Examples"))
            owned_warnings = [
                line for line in test.stdout.splitlines()
                if "warning:" in line.lower() and line.startswith(owned_roots)
            ]
            if owned_warnings:
                raise RuntimeError("clean-copy emitted Fovea-owned warnings: " + repr(owned_warnings))
            counts = [int(value) for value in re.findall(r"Executed (\d+) tests", test.stdout)]
            count = max(counts, default=0)
            if count != EXPECTED_TEST_COUNT:
                raise RuntimeError(f"clean-copy test count drifted: expected={EXPECTED_TEST_COUNT} observed={count}")
    except (OSError, ValueError, KeyError, json.JSONDecodeError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error))
        return 1

    report = {
        "schemaVersion": 1,
        "status": "passed",
        "testCount": EXPECTED_TEST_COUNT,
        "sourceDigest": source_digest,
        "components": {
            identity: {"repositoryURL": value[0], "revision": value[1]}
            for identity, value in sorted(expected.items())
        },
        "networkResolution": "public-https-exact-revision",
        "siblingRepositoryRequired": False,
    }
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        "External component clean copy passed: "
        f"tests={EXPECTED_TEST_COUNT} source={source_digest[:12]}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
