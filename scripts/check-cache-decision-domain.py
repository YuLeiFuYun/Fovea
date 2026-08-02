#!/usr/bin/env python3
"""验证缓存决策有限域、完整笛卡尔积规模和 MC/DC 见证。"""

from __future__ import annotations

from datetime import datetime, timezone
import itertools
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
DOMAIN = ROOT / "Tests/FoveaTests/Conformance/Mathematics/cache-decision-domain.json"
TEST_SOURCE = ROOT / "Tests/FoveaTests/HTTPCachePolicyTests.swift"
OUTPUT = ROOT / ".artifacts/mathematics/cache-decision-coverage.json"


def disposition(row: dict[str, str]) -> str:
    invalid_control = row["cacheControl"] in {"duplicate-max-age", "malformed"}
    forbids_storage = row["cacheControl"] == "no-store"
    invalid_vary = row["vary"] in {"wildcard", "invalid"}
    unavailable = row["varySelection"] == "unavailable"
    if invalid_control or forbids_storage or invalid_vary or unavailable:
        return "no-store"
    return "private" if row["namespace"] == "private" else "reusable"


def boolean_conditions(row: dict[str, str]) -> tuple[bool, ...]:
    return (
        row["cacheControl"] in {"duplicate-max-age", "malformed"},
        row["cacheControl"] == "no-store",
        row["vary"] in {"wildcard", "invalid"},
        row["varySelection"] == "unavailable",
        row["namespace"] == "private",
    )


def main() -> int:
    domain = json.loads(DOMAIN.read_text())
    factors: dict[str, list[str]] = domain["factors"]
    names = list(factors)
    rows = [
        dict(zip(names, values, strict=True))
        for values in itertools.product(*(factors[name] for name in names))
    ]
    errors: list[str] = []
    if len(rows) != domain["expectedCombinationCount"]:
        errors.append(
            f"笛卡尔积规模错误：actual={len(rows)} "
            f"expected={domain['expectedCombinationCount']}"
        )
    source = TEST_SOURCE.read_text()
    method = "testCacheDecisionTableExhaustsFiniteInteractionDomain_MATH_PT_003"
    if not re.search(rf"\bfunc\s+{re.escape(method)}\s*\(", source):
        errors.append("执行有限域的 Swift XCTest 不存在")

    conditions = ["invalid-control", "no-store", "invalid-vary", "selection-unavailable", "private"]
    witnesses: dict[str, dict[str, object]] = {}
    for index, name in enumerate(conditions):
        found = None
        for left, right in itertools.combinations(rows, 2):
            left_conditions = boolean_conditions(left)
            right_conditions = boolean_conditions(right)
            if left_conditions[index] == right_conditions[index]:
                continue
            if any(
                left_conditions[other] != right_conditions[other]
                for other in range(len(conditions))
                if other != index
            ):
                continue
            if disposition(left) == disposition(right):
                continue
            found = {
                "left": left,
                "right": right,
                "leftOutcome": disposition(left),
                "rightOutcome": disposition(right),
            }
            break
        if found is None:
            errors.append(f"缺少 MC/DC 独立影响见证：{name}")
        else:
            witnesses[name] = found

    report = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "factorCount": len(factors),
        "combinationCount": len(rows),
        "fullCartesianCoverage": not errors and len(rows) == domain["expectedCombinationCount"],
        "mcdcConditions": conditions,
        "mcdcWitnesses": witnesses,
        "executingTest": method,
        "claimBoundary": domain["claimBoundary"],
        "errors": errors,
    }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(
        "Cache decision coverage: "
        f"combinations={len(rows)} MC/DC={len(witnesses)}/{len(conditions)}"
    )
    print(f"Artifact: {OUTPUT.relative_to(ROOT)}")
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
