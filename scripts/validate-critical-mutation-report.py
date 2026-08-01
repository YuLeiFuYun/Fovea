#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ast
import hashlib
import json
import re
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPORT = ROOT / ".artifacts/mutation/critical-mutants.json"
MUTATION_RUNNER = ROOT / "scripts/run-critical-mutants.py"
SHA = re.compile(r"^[0-9a-f]{40}$")


def required_mutants() -> set[str]:
    tree = ast.parse(MUTATION_RUNNER.read_text(), filename=str(MUTATION_RUNNER))
    assignment = next(
        (
            node
            for node in tree.body
            if isinstance(node, ast.Assign)
            and any(isinstance(target, ast.Name) and target.id == "MUTANTS" for target in node.targets)
        ),
        None,
    )
    require(assignment is not None, "mutation runner has no MUTANTS catalog")
    require(isinstance(assignment.value, ast.List), "MUTANTS catalog must be a literal list")
    identifiers: list[str] = []
    for element in assignment.value.elts:
        require(
            isinstance(element, ast.Call)
            and isinstance(element.func, ast.Name)
            and element.func.id == "Mutant"
            and element.args,
            "MUTANTS catalog contains a non-Mutant entry",
        )
        identifier = ast.literal_eval(element.args[0])
        require(
            isinstance(identifier, str) and re.fullmatch(r"AIQA-MUT-[0-9]{3}", identifier),
            f"invalid mutation catalog identifier: {identifier!r}",
        )
        identifiers.append(identifier)
    require(len(identifiers) == len(set(identifiers)), "mutation catalog contains duplicates")
    expected = [f"AIQA-MUT-{index:03d}" for index in range(1, len(identifiers) + 1)]
    require(identifiers == expected, "critical mutant IDs must be ordered and contiguous from AIQA-MUT-001")
    return set(identifiers)


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


def current_workspace_tree() -> str:
    with tempfile.TemporaryDirectory(prefix="fovea-verify-tree-") as temporary:
        env = os.environ.copy()
        env["GIT_INDEX_FILE"] = str(Path(temporary) / "index")
        subprocess.run(["git", "read-tree", "HEAD"], cwd=ROOT, env=env, check=True)
        subprocess.run(["git", "add", "-A", "--", "."], cwd=ROOT, env=env, check=True)
        return subprocess.run(
            ["git", "write-tree"],
            cwd=ROOT,
            env=env,
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
    required_catalog = required_mutants()
    report = json.loads(report_path.read_text())
    require(isinstance(report, dict), "report must be an object")
    require(report.get("schemaVersion") == 1, "schemaVersion must be 1")
    require(report.get("producer") == "agent-declared", "producer must be agent-declared")

    verified_commit = report.get("verifiedCommit")
    require(isinstance(verified_commit, str) and SHA.fullmatch(verified_commit) is not None, "verifiedCommit must be a full lowercase Git SHA")
    require(verified_commit == (expected_commit or current_head()), "verifiedCommit does not match the expected commit")
    verified_tree = report.get("verifiedTree")
    require(isinstance(verified_tree, str) and SHA.fullmatch(verified_tree) is not None, "verifiedTree must be a full lowercase Git tree SHA")
    expected_tree = (
        subprocess.run(
            ["git", "rev-parse", f"{expected_commit}^{{tree}}"],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout.strip()
        if expected_commit
        else current_workspace_tree()
    )
    require(verified_tree == expected_tree, "verifiedTree does not match the workspace under validation")
    includes_changes = report.get("includesWorkingTreeChanges")
    require(isinstance(includes_changes, bool), "includesWorkingTreeChanges must be a boolean")
    require(isinstance(report.get("xcodeVersion"), str) and report["xcodeVersion"], "xcodeVersion is required")
    require(isinstance(report.get("swiftVersion"), str) and report["swiftVersion"], "swiftVersion is required")

    required = report.get("requiredMutants")
    require(isinstance(required, list), "requiredMutants must be an array")
    require(
        set(required) == required_catalog,
        "requiredMutants must exactly match the current required mutant catalog",
    )
    require(len(required) == len(set(required)), "requiredMutants contains duplicates")

    mutants = report.get("mutants")
    require(isinstance(mutants, list), "mutants must be an array")
    require(len(mutants) == len(required_catalog), "mutant result count mismatch")
    seen: set[str] = set()
    for mutant in mutants:
        require(isinstance(mutant, dict), "mutant entries must be objects")
        identifier = mutant.get("id")
        require(identifier in required_catalog, f"unexpected mutant id: {identifier}")
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
    require(summary.get("required") == len(required_catalog), "summary.required mismatch")
    require(summary.get("completed") == len(required_catalog), "summary.completed mismatch")
    require(summary.get("killed") == len(required_catalog), "summary.killed mismatch")
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
