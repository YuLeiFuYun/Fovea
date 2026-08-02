#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "Benchmarks/CacheLab"


def canonical_digest(path: Path) -> str:
    value = json.loads(path.read_text())
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> int:
    env = os.environ.copy()
    if not env.get("DEVELOPER_DIR"):
        env["DEVELOPER_DIR"] = subprocess.run(
            [str(ROOT / "scripts/select-xcode.sh")],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()
    binary_directory = subprocess.run(
        [
            "xcrun",
            "swift",
            "build",
            "--package-path",
            str(PACKAGE),
            "--show-bin-path",
        ],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    ).stdout.strip()
    runner = Path(binary_directory) / "CacheLabRunner"
    source_inputs = [PACKAGE / "Package.swift", *sorted((PACKAGE / "Sources").rglob("*"))]
    newest_source_mtime = max(
        path.stat().st_mtime for path in source_inputs if path.is_file()
    )
    if not runner.is_file() or runner.stat().st_mtime < newest_source_mtime:
        subprocess.run(
            [
                "xcrun",
                "swift",
                "build",
                "--package-path",
                str(PACKAGE),
                "--product",
                "CacheLabRunner",
            ],
            cwd=ROOT,
            env=env,
            stdout=subprocess.DEVNULL,
            check=True,
        )
        require(runner.is_file(), "CacheLabRunner build did not produce an executable")
    identity = json.dumps(
        {
            "commit": "1" * 40,
            "sourceTreeDigest": "2" * 64,
            "includesWorkingTreeChanges": True,
            "dependencyMode": "test-fixture",
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    env["FOVEA_CACHE_LAB_IDENTITY"] = identity
    env["FOVEA_CACHE_LAB_AKASHIC_IDENTITY"] = identity
    env["FOVEA_CACHE_LAB_PLAN_DIGEST"] = canonical_digest(
        ROOT / "Benchmarks/CacheLab/cache-plan.json"
    )
    env["FOVEA_CLAIM_FAMILY_DIGEST"] = canonical_digest(
        ROOT / "Benchmarks/statistical-claim-families.json"
    )

    with tempfile.TemporaryDirectory(prefix="cache-lab-process-model-") as directory:
        root = Path(directory)
        invalid = subprocess.run(
            [
                str(runner),
                "--formal",
                "--repetitions",
                "20",
                "--scope",
                "all",
                "--output",
                str(root / "invalid.json"),
            ],
            cwd=ROOT,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        require(
            invalid.returncode != 0,
            "monolithic twenty-repetition formal runner must be rejected",
        )

        correctness_path = root / "correctness.json"
        subprocess.run(
            [
                str(runner),
                "--formal",
                "--correctness-only",
                "--repetitions",
                "1",
                "--scope",
                "all",
                "--output",
                str(correctness_path),
            ],
            cwd=ROOT,
            env=env,
            stdout=subprocess.DEVNULL,
            check=True,
        )
        correctness = json.loads(correctness_path.read_text())
        require(
            correctness["executionMode"] == "formal-correctness"
            and correctness["runs"] == []
            and len(correctness["diskCorrectness"]) == 3,
            "formal correctness process report is incomplete",
        )

        block_path = root / "block.json"
        subprocess.run(
            [
                str(runner),
                "--formal",
                "--formal-block-index",
                "7",
                "--repetitions",
                "1",
                "--scope",
                "all",
                "--output",
                str(block_path),
            ],
            cwd=ROOT,
            env=env,
            stdout=subprocess.DEVNULL,
            check=True,
        )
        block = json.loads(block_path.read_text())
        require(
            block["executionMode"] == "formal-block"
            and block["diskCorrectness"] == []
            and len(block["runs"]) == 1
            and block["runs"][0]["repetition"] == 7,
            "formal process block report is incomplete",
        )

    print("Cache Lab formal process model regression passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
