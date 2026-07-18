#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

REQUIRED_MUTANTS = {
    "AIQA-MUT-001",
    "AIQA-MUT-002",
    "AIQA-MUT-007",
    "AIQA-MUT-008",
    "AIQA-MUT-009",
    "AIQA-MUT-015",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def current_head(root: Path) -> str:
    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise ValueError(f"cannot resolve Git HEAD: {completed.stderr.strip()}")
    return completed.stdout.strip()


def validate(report_path: Path, root: Path, expected_commit: str | None) -> str:
    report = json.loads(report_path.read_text())
    require(isinstance(report, dict), "report must be an object")
    require(report.get("schemaVersion") == 1, "schemaVersion must be 1")

    verified_commit = report.get("verifiedCommit")
    require(
        isinstance(verified_commit, str) and re.fullmatch(r"[0-9a-f]{40}", verified_commit) is not None,
        "verifiedCommit must be a full lowercase Git SHA",
    )
    expected = expected_commit or current_head(root)
    require(verified_commit == expected, f"verifiedCommit {verified_commit} does not match {expected}")

    for field in ("generatedAt", "producer", "xcodeVersion", "swiftVersion"):
        require(isinstance(report.get(field), str) and report[field], f"missing {field}")
    require(
        report["producer"] in {"agent-declared", "trusted-ci", "held-out-evaluator", "human-reviewer"},
        "invalid producer",
    )

    required = report.get("requiredMutants")
    require(isinstance(required, list), "requiredMutants must be an array")
    require(set(required) == REQUIRED_MUTANTS, "requiredMutants does not match Phase 0a catalog")
    require(len(required) == len(set(required)), "requiredMutants contains duplicates")

    mutants = report.get("mutants")
    require(isinstance(mutants, list), "mutants must be an array")
    require(len(mutants) == len(REQUIRED_MUTANTS), "mutant result count mismatch")
    seen: set[str] = set()
    status_counts = {"killed": 0, "survived": 0, "invalid": 0}

    for mutant in mutants:
        require(isinstance(mutant, dict), "mutant entry must be an object")
        identifier = mutant.get("id")
        require(identifier in REQUIRED_MUTANTS, f"unexpected mutant id {identifier}")
        require(identifier not in seen, f"duplicate mutant id {identifier}")
        seen.add(identifier)
        for field in ("description", "sourceFile", "testFilter", "logPath", "logSha256"):
            require(isinstance(mutant.get(field), str) and mutant[field], f"{identifier} missing {field}")
        status = mutant.get("status")
        require(status in status_counts, f"{identifier} invalid status {status}")
        status_counts[status] += 1
        require(isinstance(mutant.get("exitCode"), int), f"{identifier} exitCode must be integer")
        require(re.fullmatch(r"[0-9a-f]{64}", mutant["logSha256"]) is not None, f"{identifier} bad log digest")

        log_path = root / mutant["logPath"]
        require(log_path.is_file(), f"{identifier} log missing: {log_path}")
        require(sha256(log_path) == mutant["logSha256"], f"{identifier} log digest mismatch")
        log_text = log_path.read_text(errors="replace")
        require("Test Case '" in log_text and " started." in log_text, f"{identifier} test did not execute")
        if status == "killed":
            require(mutant["exitCode"] != 0, f"{identifier} killed result must have nonzero exit")
            require(" failed " in log_text or "] failed" in log_text, f"{identifier} lacks failing-test evidence")

    require(seen == REQUIRED_MUTANTS, "mutant result IDs incomplete")
    summary = report.get("summary")
    require(isinstance(summary, dict), "summary must be an object")
    require(summary.get("required") == len(REQUIRED_MUTANTS), "summary.required mismatch")
    for status, count in status_counts.items():
        require(summary.get(status) == count, f"summary.{status} mismatch")
    require(status_counts == {"killed": 6, "survived": 0, "invalid": 0}, "critical mutation gate not fully killed")

    return sha256(report_path)


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate a Fovea critical mutation report.")
    parser.add_argument(
        "report",
        nargs="?",
        default=".artifacts/mutation/critical-mutants.json",
        help="Mutation report path.",
    )
    parser.add_argument("--verified-commit", help="Expected full Git SHA; defaults to repository HEAD.")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    report_path = (root / args.report).resolve() if not Path(args.report).is_absolute() else Path(args.report)
    try:
        digest = validate(report_path, root, args.verified_commit)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Critical mutation report validation failed: {error}", file=sys.stderr)
        return 1

    print(f"Critical mutation report valid: {report_path.relative_to(root)} sha256:{digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
