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

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPORT = ROOT / ".artifacts/mutation/critical-mutants.json"
REQUIRED_MUTANTS = {f"AIQA-MUT-{index:03d}" for index in range(1, 23)}
SHA = re.compile(r"^[0-9a-f]{40}$")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def current_head() -> str:
    return subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.strip()


def resolve(relative: str) -> Path:
    path = (ROOT / relative).resolve()
    path.relative_to(ROOT.resolve())
    return path


def validate(report_path: Path, expected_commit: str | None) -> dict[str, Any]:
    report = json.loads(report_path.read_text())
    require(isinstance(report, dict), "report must be an object")
    require(report.get("schemaVersion") == 1, "schemaVersion must be 1")
    require(report.get("producer") == "agent-declared", "producer must be agent-declared")

    verified_commit = report.get("verifiedCommit")
    require(isinstance(verified_commit, str) and SHA.fullmatch(verified_commit) is not None, "verifiedCommit must be a full lowercase Git SHA")
    require(verified_commit == (expected_commit or current_head()), "verifiedCommit does not match the expected commit")

    required = report.get("requiredMutants")
    require(isinstance(required, list), "requiredMutants must be an array")
    require(set(required) == REQUIRED_MUTANTS, "requiredMutants must exactly match AIQA-MUT-001 through AIQA-MUT-022")
    require(len(required) == len(set(required)), "requiredMutants contains duplicates")

    mutants = report.get("mutants")
    require(isinstance(mutants, list), "mutants must be an array")
    require(len(mutants) == len(REQUIRED_MUTANTS), "mutant result count mismatch")
    seen: set[str] = set()
    for mutant in mutants:
        require(isinstance(mutant, dict), "mutant entries must be objects")
        identifier = mutant.get("id")
        require(identifier in REQUIRED_MUTANTS, f"unexpected mutant id: {identifier}")
        require(identifier not in seen, f"duplicate mutant result: {identifier}")
        seen.add(identifier)
        require(mutant.get("status") == "killed", f"{identifier} is not killed")
        require(isinstance(mutant.get("testFilter"), str) and mutant["testFilter"], f"{identifier} lacks a test filter")
        require(isinstance(mutant.get("sourceFile"), str) and mutant["sourceFile"], f"{identifier} lacks a source file")
        log_relative = mutant.get("logPath")
        require(isinstance(log_relative, str), f"{identifier} lacks a log path")
        log_path = resolve(log_relative)
        require(log_path.is_file(), f"{identifier} log is missing")
        require(sha256(log_path) == mutant.get("logSha256"), f"{identifier} log digest mismatch")
        output = log_path.read_text(errors="replace")
        require("Test Case '" in output and " started." in output, f"{identifier} target test did not start")

    summary = report.get("summary")
    require(isinstance(summary, dict), "summary must be an object")
    require(summary.get("required") == len(REQUIRED_MUTANTS), "summary.required mismatch")
    require(summary.get("killed") == len(REQUIRED_MUTANTS), "summary.killed mismatch")
    require(summary.get("survived") == 0, "summary.survived must be zero")
    require(summary.get("invalid") == 0, "summary.invalid must be zero")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate the Fovea critical mutation report.")
    parser.add_argument("report", nargs="?", default=str(DEFAULT_REPORT))
    parser.add_argument("--expected-commit")
    args = parser.parse_args()
    try:
        report_path = Path(args.report).resolve()
        validate(report_path, args.expected_commit)
        print(
            f"Critical mutation report valid: {report_path.relative_to(ROOT)} "
            f"sha256:{sha256(report_path)}"
        )
        return 0
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"Critical mutation report invalid: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
