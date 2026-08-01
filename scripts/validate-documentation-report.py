#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPORT = ROOT / ".artifacts/docs/documentation.json"
COMMIT = re.compile(r"^[0-9a-f]{40,64}$")
DIGEST = re.compile(r"^[0-9a-f]{64}$")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate DocC and public API documentation evidence.")
    parser.add_argument("report", nargs="?", default=str(DEFAULT_REPORT))
    parser.add_argument("--expected-commit")
    parser.add_argument("--expected-tree")
    parser.add_argument("--require-clean-tree", action="store_true")
    args = parser.parse_args()
    try:
        path = Path(args.report).resolve()
        data = json.loads(path.read_text())
        require(data.get("schemaVersion") == 1, "schemaVersion must be 1")
        generated = data.get("generatedAt")
        require(isinstance(generated, str), "generatedAt is required")
        dt.datetime.fromisoformat(generated.replace("Z", "+00:00"))
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
            require(dirty is False, "trusted documentation evidence must use a clean tree")
        require(data.get("status") == "passed", "documentation status is not passed")
        require(data.get("missingModules") == [], "symbol graphs are missing")
        require(data.get("missingPublicTypes") == [], "public types are undocumented")
        totals = data.get("totals")
        require(isinstance(totals, dict), "totals are required")
        require(
            totals.get("publicTypeDocumentationPercent")
            >= totals.get("publicTypeMinimumPercent"),
            "public type documentation threshold failed",
        )
        require(
            totals.get("publicSymbolDocumentationPercent")
            >= totals.get("publicSymbolMinimumPercent"),
            "public symbol documentation threshold failed",
        )
        require(
            totals.get("publicSymbolCount") <= totals.get("publicSymbolMaximumCount"),
            "total public API symbol budget failed",
        )
        api_budget = data.get("publicAPIBudget")
        require(isinstance(api_budget, dict), "public API budget evidence is required")
        require(api_budget.get("path") == "docs/public-api-budget.json", "unexpected API budget path")
        budget_path = ROOT / api_budget["path"]
        budget_digest = api_budget.get("sha256")
        require(
            isinstance(budget_digest, str) and DIGEST.fullmatch(budget_digest) is not None,
            "invalid API budget digest",
        )
        require(
            budget_path.is_file()
            and hashlib.sha256(budget_path.read_bytes()).hexdigest() == budget_digest,
            "API budget digest mismatch",
        )
        require(api_budget.get("violations") == {}, "public API budget contains violations")
        log = ROOT / data.get("log", "")
        digest = data.get("logSha256")
        require(isinstance(digest, str) and DIGEST.fullmatch(digest) is not None, "invalid log digest")
        require(log.is_file() and hashlib.sha256(log.read_bytes()).hexdigest() == digest, "log digest mismatch")
        print(f"Documentation report valid: {path.relative_to(ROOT)}")
        return 0
    except (OSError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"Documentation report invalid: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
