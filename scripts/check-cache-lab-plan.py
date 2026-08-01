#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAN = ROOT / "Benchmarks/CacheLab/cache-plan.json"
ARCHIVED_PLAN = ROOT / "Benchmarks/CacheLab/plans/cache-plan-v1.json"
LOCK = ROOT / "docs/research/cache-comparator-lock.json"
RESOLVED = ROOT / "Benchmarks/CacheLab/Package.resolved"
ARTIFACT = ROOT / ".artifacts/cache-lab/plan-verification.json"


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def main() -> int:
    plan = json.loads(PLAN.read_text())
    archived = json.loads(ARCHIVED_PLAN.read_text())
    lock = json.loads(LOCK.read_text())
    if plan.get("schemaVersion") != 2 or plan.get("planID") != "FOVEA-CACHE-LAB-V2":
        fail("unexpected Cache Lab plan identity")
    if plan.get("status") != "preregistered-before-next-formal-results":
        fail("Cache Lab V2 claim families must remain preregistered before the next formal run")
    if archived.get("schemaVersion") != 1 or archived.get("planID") != "FOVEA-CACHE-LAB-V1":
        fail("Cache Lab V1 archive is missing or changed identity")
    if plan.get("archivedPlan") != "Benchmarks/CacheLab/plans/cache-plan-v1.json":
        fail("Cache Lab V2 must bind the archived V1 plan")
    if plan.get("statisticalClaimFamilies") != "Benchmarks/statistical-claim-families.json":
        fail("Cache Lab V2 must bind the statistical claim-family registry")
    if not (ROOT / plan["statisticalClaimFamilies"]).is_file():
        fail("statistical claim-family registry is missing")

    claim = plan.get("claimPolicy", {})
    performance = claim.get("performance", "")
    if "TOST-equivalent" not in performance or "noninferior" not in performance or "best-within-scope" not in performance:
        fail("Cache Lab V2 performance policy must require scoped superiority, TOST equivalence, or noninferiority")
    if "blocks only its claim family" not in claim.get("scope", ""):
        fail("Cache Lab V2 must localize inconclusive evidence to its claim family")
    if claim.get("semanticStratification") != (
        "Only contestants in the same semanticGroup and durabilityLevel are ranked directly. "
        "Native PINCache results remain descriptive."
    ):
        fail("Cache Lab semantic stratification policy is missing")

    disk = plan.get("comparators", {}).get("disk")
    if not isinstance(disk, list) or len(disk) != 2:
        fail("Cache Lab V2 must declare native and wrapped PIN disk contestants")
    by_contestant = {item.get("contestant"): item for item in disk}
    native = by_contestant.get("PINDiskCacheNative", {})
    wrapped = by_contestant.get("PINDiskCacheDurableValidated", {})
    if native.get("durabilityLevel") != "D1" or native.get("rankingRole") != "descriptive":
        fail("native PINCache must remain a descriptive D1 contestant")
    if wrapped.get("durabilityLevel") != "D5" or wrapped.get("rankingRole") != "primary":
        fail("durable-validated PIN wrapper must be the D5 primary contestant")
    expected_wrapper = {
        "pin-write-completes",
        "data-file-fsync",
        "data-parent-directory-fsync",
        "api-readback-content-id-validation",
        "durable-proof-publication",
        "proof-gates-visibility",
    }
    if set(wrapped.get("wrapperSemantics", [])) != expected_wrapper:
        fail("durable PIN wrapper semantics are incomplete")
    if "not to native PINCache" not in wrapped.get("attribution", ""):
        fail("wrapper semantics must not be attributed to native PINCache")

    statistics = plan.get("statistics", {})
    if statistics.get("repetitions") != 20:
        fail("formal Cache Lab must retain twenty repetitions")
    if statistics.get("bootstrapIterations") != 10_000:
        fail("Cache Lab bootstrap count must remain 10000")
    if statistics.get("equivalenceMethod") != "paired-bootstrap-TOST":
        fail("Cache Lab V2 must use paired bootstrap TOST")
    if statistics.get("multipleComparisonCorrection") != "Holm-within-metric-family":
        fail("Cache Lab V2 must retain Holm correction")

    primary_metrics = {
        metric
        for section in ("memoryWorkloads", "diskWorkloads")
        for workload in plan.get(section, {}).values()
        for metric in workload.get("primaryMetrics", [])
    }
    rules = plan.get("metricDecisionRules", {})
    if set(rules) != primary_metrics:
        fail("every Cache Lab primary metric must have exactly one decision rule")
    for metric, rule in rules.items():
        if rule.get("scale") not in {"absolute-difference", "log-ratio"}:
            fail(f"{metric}: invalid decision scale")
        if rule.get("direction") not in {"higher", "lower"}:
            fail(f"{metric}: invalid metric direction")
        margins = [
            rule.get("equivalenceMargin"),
            rule.get("nonInferiorityMargin"),
            rule.get("superiorityMargin"),
        ]
        if not all(isinstance(value, (int, float)) and value > 0 for value in margins):
            fail(f"{metric}: all decision margins must be positive")

    expected = {"LRUCache", "PINCache"}
    items = {item["name"]: item for item in lock.get("comparators", [])}
    if set(items) != expected:
        fail("Cache Lab lock must contain LRUCache and PINCache")
    for name, item in items.items():
        source = ROOT / ".artifacts/cache-comparators/sources" / name
        head = subprocess.run(
            ["git", "-C", str(source), "rev-parse", "HEAD"],
            text=True,
            capture_output=True,
            check=False,
        )
        if head.returncode != 0 or head.stdout.strip() != item["exactCommit"]:
            fail(f"{name} checkout differs from Cache Lab lock")
        dirty = subprocess.run(
            ["git", "-C", str(source), "status", "--porcelain"],
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()
        if dirty:
            fail(f"{name} Cache Lab checkout is dirty")

    resolved = json.loads(RESOLVED.read_text())
    pins = {pin["identity"]: pin for pin in resolved.get("pins", [])}
    operation = pins.get("pinoperation", {}).get("state", {})
    if operation.get("version") != "1.2.3" or operation.get("revision") != "a74f978733bdaf982758bfa23d70a189f4b4c1b6":
        fail("PINOperation transitive dependency is not exactly locked")
    required_files = [
        "Benchmarks/CacheLab/Sources/CacheLabCore/CacheContestants.swift",
        "Benchmarks/CacheLab/Sources/CacheLabCore/PINDurableValidatedDiskContestant.swift",
        "Benchmarks/CacheLab/Sources/CacheLabCore/CacheWorkloads.swift",
        "Benchmarks/CacheLab/Tests/CacheLabTests/CacheLabTests.swift",
        "scripts/analyze-cache-lab.py",
    ]
    if any(not (ROOT / path).is_file() for path in required_files):
        fail("Cache Lab V2 implementation is incomplete")

    digest = hashlib.sha256(canonical(plan)).hexdigest()
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(
        json.dumps(
            {
                "schemaVersion": 2,
                "planID": plan["planID"],
                "planSHA256": digest,
                "archivedPlanSHA256": hashlib.sha256(canonical(archived)).hexdigest(),
                "comparators": sorted(items),
                "status": "passed",
            },
            indent=2,
            sort_keys=True,
        ) + "\n"
    )
    print(f"Cache Lab plan valid: {plan['planID']} sha256:{digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
