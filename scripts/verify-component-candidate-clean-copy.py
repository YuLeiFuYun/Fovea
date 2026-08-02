#!/usr/bin/env python3
"""Verify Fovea against a materialized, Git-free Akashic release candidate."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / ".artifacts/external-components/candidate-clean-copy.json"
LOG = ROOT / ".artifacts/external-components/candidate-clean-copy-swift-test.log"
COPY_PATHS = ("Sources", "Tests", "Tools", "Examples/FoveaGalleryDemo")
EXPECTED_TEST_COUNT = 478


def run(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    timeout: int = 1200,
) -> subprocess.CompletedProcess[str]:
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
        rows.append(
            relative.encode()
            + b"\0"
            + hashlib.sha256(path.read_bytes()).hexdigest().encode()
            + b"\n"
        )
    return hashlib.sha256(b"".join(rows)).hexdigest()


def copy_source(destination: Path) -> None:
    for relative in ("Package.swift", "Package.resolved"):
        shutil.copy2(ROOT / relative, destination / relative)
    for relative in COPY_PATHS:
        shutil.copytree(
            ROOT / relative,
            destination / relative,
            ignore=shutil.ignore_patterns(
                ".DS_Store", ".build", ".swiftpm", ".artifacts", "__pycache__", "*.pyc"
            ),
        )


def find_dependency(value: Any, identity: str) -> dict[str, Any] | None:
    if isinstance(value, dict):
        if str(value.get("identity", "")).lower() == identity.lower():
            return value
        for child in value.values():
            found = find_dependency(child, identity)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find_dependency(child, identity)
            if found is not None:
                return found
    return None


def capture_candidate_identity(
    candidate: Path, env: dict[str, str]
) -> dict[str, Any]:
    tool = candidate / "Tools/Identity/capture_source_identity.py"
    if not tool.is_file():
        raise RuntimeError("Akashic candidate lacks source-identity capture tool")
    with tempfile.TemporaryDirectory(prefix="akashic-candidate-identity-") as directory:
        output = Path(directory) / "identity.json"
        completed = run(
            ["python3", str(tool), "--output", str(output)],
            cwd=candidate,
            env=env,
            timeout=120,
        )
        if completed.returncode != 0 or not output.is_file():
            raise RuntimeError(
                "Akashic candidate source identity failed:\n" + completed.stdout
            )
        identity = json.loads(output.read_text())
    if identity.get("fileCount") != len(identity.get("files", [])):
        raise RuntimeError("Akashic candidate source identity file count is inconsistent")
    digest = identity.get("sourceIdentitySHA256")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise RuntimeError("Akashic candidate source identity digest is invalid")
    return identity


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--akashic-source", type=Path, required=True)
    parser.add_argument("--expected-test-count", type=int, default=EXPECTED_TEST_COUNT)
    args = parser.parse_args()

    candidate = args.akashic_source.expanduser().resolve()
    env = os.environ.copy()
    selection = run([str(ROOT / "scripts/select-xcode.sh")], cwd=ROOT, env=env, timeout=30)
    if selection.returncode != 0:
        print(selection.stdout)
        return selection.returncode
    env["DEVELOPER_DIR"] = selection.stdout.strip()

    try:
        if not (candidate / "Package.swift").is_file():
            raise RuntimeError("Akashic candidate is not a Swift package")
        if (candidate / ".git").exists():
            raise RuntimeError("Akashic candidate must be a materialized Git-free source copy")
        candidate_identity = capture_candidate_identity(candidate, env)

        with tempfile.TemporaryDirectory(prefix="fovea-component-candidate-copy-") as directory:
            copy = Path(directory) / "Fovea"
            copy.mkdir()
            copy_source(copy)
            source_digest = file_digest(copy)

            resolve = run(["xcrun", "swift", "package", "resolve"], cwd=copy, env=env)
            if resolve.returncode != 0:
                raise RuntimeError("candidate-copy dependency resolution failed:\n" + resolve.stdout)
            edit = run(
                [
                    "xcrun",
                    "swift",
                    "package",
                    "edit",
                    "Akashic",
                    "--path",
                    str(candidate),
                ],
                cwd=copy,
                env=env,
            )
            if edit.returncode != 0:
                raise RuntimeError("candidate-copy Akashic edit failed:\n" + edit.stdout)

            dependencies = run(
                ["xcrun", "swift", "package", "show-dependencies", "--format", "json"],
                cwd=copy,
                env=env,
            )
            if dependencies.returncode != 0:
                raise RuntimeError("candidate-copy dependency inspection failed:\n" + dependencies.stdout)
            dependency = find_dependency(json.loads(dependencies.stdout), "akashic")
            if dependency is None or Path(str(dependency.get("path", ""))).resolve() != candidate:
                raise RuntimeError("candidate-copy did not resolve Akashic to the supplied source copy")

            test = run(["xcrun", "swift", "test"], cwd=copy, env=env)
            LOG.parent.mkdir(parents=True, exist_ok=True)
            LOG.write_text(test.stdout)
            if test.returncode != 0:
                raise RuntimeError("candidate-copy tests failed; see " + str(LOG.relative_to(ROOT)))
            owned_roots = tuple(
                str(copy / prefix) for prefix in ("Sources", "Tests", "Tools", "Examples")
            )
            owned_warnings = [
                line
                for line in test.stdout.splitlines()
                if "warning:" in line.lower() and line.startswith(owned_roots)
            ]
            if owned_warnings:
                raise RuntimeError(
                    "candidate-copy emitted Fovea-owned warnings: " + repr(owned_warnings)
                )
            counts = [int(value) for value in re.findall(r"Executed (\d+) tests", test.stdout)]
            count = max(counts, default=0)
            if count != args.expected_test_count:
                raise RuntimeError(
                    "candidate-copy test count drifted: "
                    f"expected={args.expected_test_count} observed={count}"
                )
    except (
        OSError,
        ValueError,
        KeyError,
        json.JSONDecodeError,
        RuntimeError,
        subprocess.TimeoutExpired,
    ) as error:
        print(str(error))
        return 1

    report = {
        "schemaVersion": 1,
        "status": "passed",
        "testCount": args.expected_test_count,
        "foveaSourceDigest": source_digest,
        "akashicCandidate": {
            "fileCount": candidate_identity["fileCount"],
            "sourceIdentitySHA256": candidate_identity["sourceIdentitySHA256"],
            "gitMetadataPresent": False,
        },
        "dependencyMode": "local-git-free-candidate-copy",
        "publicRevisionClaim": False,
        "trustedCIClaim": False,
    }
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        "External Akashic candidate copy passed: "
        f"tests={args.expected_test_count} "
        f"candidate={candidate_identity['sourceIdentitySHA256'][:12]}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
