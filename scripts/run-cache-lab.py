#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "Benchmarks/CacheLab"
ARTIFACT_ROOT = ROOT / ".artifacts/cache-lab"


def run(command: list[str], *, env: dict[str, str] | None = None, timeout: int = 1200) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
    )
    if result.returncode != 0:
        print(result.stdout[-30000:], file=sys.stderr)
        raise SystemExit(result.returncode)
    return result


def environment() -> dict[str, str]:
    env = os.environ.copy()
    if not env.get("DEVELOPER_DIR"):
        env["DEVELOPER_DIR"] = run([str(ROOT / "scripts/select-xcode.sh")], timeout=120).stdout.strip()
    return env


def git_identity() -> dict[str, Any]:
    head = run(["git", "rev-parse", "HEAD"], timeout=120).stdout.strip()
    status = run(["git", "status", "--porcelain=v1", "-z"], timeout=120).stdout
    digest = hashlib.sha256()
    digest.update(b"fovea-worktree-v1\0")
    digest.update(head.encode())
    digest.update(
        subprocess.run(
            ["git", "diff", "--binary", "HEAD"], cwd=ROOT, stdout=subprocess.PIPE, check=True
        ).stdout
    )
    untracked = run(["git", "ls-files", "--others", "--exclude-standard", "-z"], timeout=120).stdout.split("\0")
    for relative in sorted(value for value in untracked if value):
        path = ROOT / relative
        if path.is_file() and not path.is_symlink():
            digest.update(relative.encode())
            digest.update(b"\0")
            digest.update(path.read_bytes())
            digest.update(b"\0")
    return {
        "commit": head,
        "sourceTreeDigest": digest.hexdigest(),
        "includesWorkingTreeChanges": bool(status),
    }


def canonical_digest(path: Path) -> str:
    value = json.loads(path.read_text())
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the standalone Fovea Cache Lab.")
    parser.add_argument("--mode", choices=["calibration", "formal"], default="calibration")
    parser.add_argument("--repetitions", type=int)
    parser.add_argument("--skip-tests", action="store_true")
    args = parser.parse_args()
    repetitions = args.repetitions or (20 if args.mode == "formal" else 3)
    if args.mode == "formal" and repetitions < 20:
        raise SystemExit("formal Cache Lab requires at least 20 repetitions")
    env = environment()
    run(["python3", "scripts/check-cache-lab-plan.py"], env=env, timeout=180)
    if not args.skip_tests:
        test = run(
            ["xcrun", "swift", "test", "--package-path", str(PACKAGE)],
            env=env,
            timeout=900,
        )
        (ARTIFACT_ROOT / "cache-lab-tests.log").parent.mkdir(parents=True, exist_ok=True)
        (ARTIFACT_ROOT / "cache-lab-tests.log").write_text(test.stdout)
    identity = git_identity()
    env["FOVEA_CACHE_LAB_IDENTITY"] = json.dumps(identity, sort_keys=True, separators=(",", ":"))
    env["FOVEA_CACHE_LAB_PLAN_DIGEST"] = canonical_digest(ROOT / "Benchmarks/CacheLab/cache-plan.json")
    env["FOVEA_CLAIM_FAMILY_DIGEST"] = canonical_digest(ROOT / "Benchmarks/statistical-claim-families.json")
    ARTIFACT_ROOT.mkdir(parents=True, exist_ok=True)
    raw = ARTIFACT_ROOT / f"{args.mode}-raw-results.json"
    command = [
        "xcrun", "swift", "run", "--package-path", str(PACKAGE), "-c", "release",
        "CacheLabRunner", "--repetitions", str(repetitions), "--output", str(raw),
    ]
    if args.mode == "formal":
        command.append("--formal")
    result = run(command, env=env, timeout=7200)
    (ARTIFACT_ROOT / f"{args.mode}-runner.log").write_text(result.stdout)
    analysis = ARTIFACT_ROOT / f"{args.mode}-analysis.json"
    analyze = run(
        ["python3", "scripts/analyze-cache-lab.py", "--input", str(raw), "--output", str(analysis)],
        env=env,
        timeout=600,
    )
    print(result.stdout, end="")
    print(analyze.stdout, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
