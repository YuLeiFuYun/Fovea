#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMMIT = re.compile(r"^[0-9a-f]{40,64}$")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate real-network evidence.")
    parser.add_argument("report", nargs="?", default=".artifacts/live-network/network-lab.json")
    parser.add_argument("--expected-commit")
    parser.add_argument("--expected-tree")
    parser.add_argument("--require-clean-tree", action="store_true")
    args = parser.parse_args()
    try:
        path = Path(args.report).resolve()
        data = json.loads(path.read_text())
        require(data.get("schemaVersion") == 2, "schemaVersion must be 2")
        commit = data.get("verifiedCommit")
        tree = data.get("verifiedTree")
        require(isinstance(commit, str) and COMMIT.fullmatch(commit) is not None, "invalid commit")
        require(isinstance(tree, str) and COMMIT.fullmatch(tree) is not None, "invalid tree")
        if args.expected_commit:
            require(commit == args.expected_commit, "commit mismatch")
        if args.expected_tree:
            require(tree == args.expected_tree, "tree mismatch")
        dirty = data.get("includesWorkingTreeChanges")
        require(isinstance(dirty, bool), "includesWorkingTreeChanges must be boolean")
        if args.require_clean_tree:
            require(dirty is False, "trusted evidence must come from a clean tree")
        require(data.get("status") == "passed", "status must be passed")
        require(isinstance(data.get("xcodeVersion"), str) and data["xcodeVersion"], "missing Xcode version")
        require(isinstance(data.get("swiftVersion"), str) and data["swiftVersion"], "missing Swift version")
        attempts = data.get("attempts")
        require(isinstance(attempts, list) and 1 <= len(attempts) <= 3, "invalid attempts")
        require(attempts[-1].get("passed") is True, "final attempt did not pass")
        lab = data.get("lab")
        require(isinstance(lab, dict), "lab report is missing")
        require(lab.get("schemaVersion") == 4, "lab schemaVersion must be 4")
        require(lab.get("allSucceeded") is True, "not all live cases succeeded")
        require(lab.get("allExpectationsSatisfied") is True, "expectations failed")
        require(lab.get("allInvariantsSatisfied") is True, "invariants failed")
        cases = lab.get("cases")
        require(isinstance(cases, list) and len(cases) >= 4, "at least four live cases are required")
        origins = {case.get("originLabel") for case in cases if isinstance(case, dict)}
        require(len(origins) >= 4, "at least four independent origins are required")
        for case in cases:
            require(isinstance(case, dict), "case must be an object")
            case_id = case.get("caseID")
            origin_label = case.get("originLabel")
            require(
                isinstance(case_id, str)
                and re.fullmatch(r"[a-z0-9-]{1,64}", case_id) is not None,
                "invalid case identifier",
            )
            require(
                isinstance(origin_label, str)
                and (
                    re.fullmatch(r"private-[0-9a-f]{16}", origin_label) is not None
                    or re.fullmatch(r"[a-z0-9.-]{1,253}", origin_label) is not None
                )
                and "://" not in origin_label,
                "invalid or sensitive origin label",
            )
            require(case.get("success") is True, f"live case failed: {case_id}")
            require(case.get("networkMetricsObserved") is True, "URLSession metrics missing")
            require(case.get("networkTimingObserved") is True, "URLSession task timing missing")
            require(
                (case.get("networkTaskDurationNanoseconds") or 0) > 0,
                "URLSession task duration missing",
            )
            require(case.get("singleFlightObserved") is True, "single-flight was not observed")
            require((case.get("networkTransactionCount") or 0) >= 1, "network transaction missing")
            require(bool(case.get("networkProtocolNames")), "network protocol missing")
            require(case.get("targetPixelInvariantSatisfied") is True, "target pixel bound failed")
        require(
            any((case.get("redirectCount") or 0) >= 1 for case in cases),
            "no real redirect was observed",
        )
        require(
            any((case.get("networkTransactionCount") or 0) >= 2 for case in cases),
            "no real redirect/multi-transaction case was observed",
        )
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        print(f"Live network report valid: {path.relative_to(ROOT)} sha256:{digest}")
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Live network report invalid: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
