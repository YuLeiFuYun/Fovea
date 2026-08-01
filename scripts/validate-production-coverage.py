#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPORT = ROOT / ".artifacts/coverage/production-coverage.json"
COMMIT = re.compile(r"^[0-9a-f]{40,64}$")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate production coverage evidence.")
    parser.add_argument("report", nargs="?", default=str(DEFAULT_REPORT))
    parser.add_argument("--expected-commit")
    parser.add_argument("--expected-tree")
    parser.add_argument("--require-clean-tree", action="store_true")
    args = parser.parse_args()
    try:
        path = Path(args.report).resolve()
        data = json.loads(path.read_text())
        require(data.get("schemaVersion") == 2, "schemaVersion must be 2")
        generated_at = data.get("generatedAt")
        require(isinstance(generated_at, str), "generatedAt is required")
        dt.datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
        commit = data.get("verifiedCommit")
        tree = data.get("verifiedTree")
        require(isinstance(commit, str) and COMMIT.fullmatch(commit) is not None, "invalid commit")
        require(isinstance(tree, str) and COMMIT.fullmatch(tree) is not None, "invalid tree")
        if args.expected_commit:
            require(commit == args.expected_commit, "verifiedCommit mismatch")
        if args.expected_tree:
            require(tree == args.expected_tree, "verifiedTree mismatch")
        dirty = data.get("includesWorkingTreeChanges")
        require(isinstance(dirty, bool), "includesWorkingTreeChanges must be boolean")
        if args.require_clean_tree:
            require(dirty is False, "trusted coverage evidence must come from a clean tree")
        require(data.get("status") == "passed", "coverage status is not passed")
        require(data.get("failedMetrics") == [], "aggregate coverage failures are present")
        require(data.get("failedModules") == [], "module coverage failures are present")
        require(data.get("failedFiles") == [], "file coverage failures are present")
        totals = data.get("totals")
        require(isinstance(totals, dict) and totals, "totals are required")
        for metric, summary in totals.items():
            require(isinstance(summary, dict), f"invalid total: {metric}")
            require(
                summary.get("percent", -1) >= summary.get("minimumPercent", float("inf")),
                f"aggregate threshold failed: {metric}",
            )
        modules = data.get("modules")
        module_thresholds = data.get("moduleLineThresholds")
        require(isinstance(modules, dict), "module summaries are required")
        require(isinstance(module_thresholds, dict), "module thresholds are required")
        for module, minimum in module_thresholds.items():
            require(
                modules.get(module, {}).get("lines", {}).get("percent", -1) >= minimum,
                f"module threshold failed: {module}",
            )
        files = data.get("files")
        file_thresholds = data.get("criticalFileLineThresholds")
        require(isinstance(files, dict) and files, "file summaries are required")
        require(isinstance(file_thresholds, dict), "critical file thresholds are required")
        require(data.get("includedFileCount") == len(files), "includedFileCount mismatch")
        for file, minimum in file_thresholds.items():
            require(
                files.get(file, {}).get("lines", {}).get("percent", -1) >= minimum,
                f"critical file threshold failed: {file}",
            )
        uncovered = data.get("uncoveredFunctions")
        require(isinstance(uncovered, list), "uncoveredFunctions must be an array")
        print(f"Production coverage report valid: {path.relative_to(ROOT)}")
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Production coverage report invalid: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
