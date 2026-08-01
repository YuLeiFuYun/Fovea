#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

COMMIT = re.compile(r"^[0-9a-fA-F]{7,64}$")


def run(command: list[str], cwd: Path, env: dict[str, str], log: list[str]) -> int:
    log.append(f"$ {' '.join(command)}\n")
    completed = subprocess.run(
        command,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    log.append(completed.stdout)
    log.append(f"[exit {completed.returncode}]\n")
    return completed.returncode


def git_output(root: Path, *arguments: str) -> str:
    completed = subprocess.run(
        ["git", *arguments],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or "git command failed")
    return completed.stdout.strip()


def resolve_commit(root: Path, value: str) -> str:
    if not COMMIT.fullmatch(value):
        raise ValueError(f"invalid commit: {value}")
    resolved = git_output(root, "rev-parse", f"{value}^{{commit}}")
    if not COMMIT.fullmatch(resolved):
        raise ValueError(f"could not resolve commit: {value}")
    return resolved


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_report(data: dict[str, Any], base: str, head: str, log_path: Path) -> None:
    if data.get("schemaVersion") != 1:
        raise ValueError("rollback schemaVersion must be 1")
    if data.get("baseCommit") != base or data.get("headCommit") != head:
        raise ValueError("rollback report commit binding mismatch")
    if data.get("status") != "pass":
        raise ValueError("rollback verification did not pass")
    checks = data.get("checks")
    if not isinstance(checks, list) or not checks:
        raise ValueError("rollback checks missing")
    if any(check.get("exitCode") != 0 for check in checks):
        raise ValueError("rollback report contains failed check")
    if data.get("logDigest") != f"sha256:{sha256(log_path)}":
        raise ValueError("rollback log digest mismatch")


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify that a Fovea change can be rolled back to a clean base commit.")
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--output-dir", default=".artifacts/rollback")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    output_dir = (root / args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    log_path = output_dir / "rollback.log"
    report_path = output_dir / "rollback-report.json"

    try:
        base = resolve_commit(root, args.base)
        head = git_output(root, "rev-parse", f"{args.head}^{{commit}}")
        current = git_output(root, "rev-parse", "HEAD^{commit}")
        if head != current:
            raise ValueError("rollback head must equal the checked-out HEAD")
        if base == head:
            raise ValueError("rollback base and head must differ")
        if subprocess.run(
            ["git", "merge-base", "--is-ancestor", base, head], cwd=root, check=False
        ).returncode != 0:
            raise ValueError("rollback base is not an ancestor of head")

        worktree_parent = Path(tempfile.mkdtemp(prefix="fovea-rollback-"))
        worktree = worktree_parent / "worktree"
        log: list[str] = []
        checks: list[dict[str, Any]] = []
        added = False
        try:
            add_code = run(
                ["git", "worktree", "add", "--detach", str(worktree), base],
                root,
                os.environ.copy(),
                log,
            )
            if add_code != 0:
                raise RuntimeError("failed to create rollback worktree")
            added = True
            env = os.environ.copy()
            developer_dir = subprocess.run(
                [str(worktree / "scripts/select-xcode.sh")],
                cwd=worktree,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            ).stdout.strip()
            env["DEVELOPER_DIR"] = developer_dir
            boundary_script = (
                "scripts/check-architecture-boundaries.py"
                if (worktree / "scripts/check-architecture-boundaries.py").is_file()
                else "scripts/check-phase0a-surface.py"
            )
            strict_runner = worktree / "scripts/run-swift-strict.py"
            if strict_runner.is_file():
                test_command = ["python3", str(strict_runner), "test"]
                release_command = ["python3", str(strict_runner), "build", "-c", "release"]
            else:
                test_command = ["xcrun", "swift", "test", "-Xswiftc", "-warnings-as-errors"]
                release_command = [
                    "xcrun", "swift", "build", "-c", "release", "-Xswiftc", "-warnings-as-errors"
                ]
            commands = [
                ("boundaries", ["python3", boundary_script]),
                (
                    "format",
                    ["xcrun", "swift-format", "lint", "--strict", "-r", "Sources", "Tests", "Package.swift"],
                ),
                ("tests", test_command),
                ("release", release_command),
            ]
            for identifier, command in commands:
                code = run(command, worktree, env, log)
                checks.append({"id": identifier, "exitCode": code})
                if code != 0:
                    break
        finally:
            log_path.write_text("".join(log))
            if added:
                subprocess.run(
                    ["git", "worktree", "remove", "--force", str(worktree)],
                    cwd=root,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False,
                )
            shutil.rmtree(worktree_parent, ignore_errors=True)
            subprocess.run(
                ["git", "worktree", "prune"], cwd=root, stdout=subprocess.DEVNULL, check=False
            )

        status = "pass" if len(checks) == 4 and all(check["exitCode"] == 0 for check in checks) else "fail"
        report = {
            "schemaVersion": 1,
            "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "baseCommit": base,
            "headCommit": head,
            "status": status,
            "checks": checks,
            "log": str(log_path.relative_to(root)),
            "logDigest": f"sha256:{sha256(log_path)}",
        }
        report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        validate_report(report, base, head, log_path)
        print(f"Rollback gate passed: {base[:7]} <- {head[:7]}")
        print(f"Rollback report: {report_path.relative_to(root)} sha256:{sha256(report_path)}")
        return 0
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Rollback gate failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
