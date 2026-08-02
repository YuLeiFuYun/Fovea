#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAN = ROOT / "Benchmarks/W7ConcurrencyLab/experiment-plan.json"
CLAIMS = ROOT / "Benchmarks/W7ConcurrencyLab/claim-families.json"
WORKLOADS = ROOT / "Benchmarks/workload-registry.json"


def canonical(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def main() -> int:
    plan = json.loads(PLAN.read_text())
    claims = json.loads(CLAIMS.read_text())
    workloads = json.loads(WORKLOADS.read_text())
    errors: list[str] = []
    execution = plan.get("execution", {})
    if plan.get("schemaVersion") != 7 or plan.get("planID") != "FOVEA-W7-CONCURRENCY-V7":
        errors.append("unexpected W7 plan identity")
    if plan.get("status") != "preregistered-after-v6-calibration-before-formal-results":
        errors.append("W7 V7 plan must remain preregistered before formal results")
    if plan.get("supersedes") != "Benchmarks/W7ConcurrencyLab/plans/experiment-plan-v6.json":
        errors.append("W7 V6 archive binding is missing")
    archived_plan = json.loads(
        (ROOT / "Benchmarks/W7ConcurrencyLab/plans/experiment-plan-v6.json").read_text()
    )
    if archived_plan.get("schemaVersion") != 6 or archived_plan.get("planID") != "FOVEA-W7-CONCURRENCY-V6":
        errors.append("archived W7 V6 plan identity drifted")
    expected_comparators = [
        "Apple URLSession + URLCache + ImageIO", "Fovea", "Nuke", "Kingfisher",
        "SDWebImage", "PINRemoteImage",
    ]
    if plan.get("comparators") != expected_comparators:
        errors.append("W7 V7 A-tier headless comparator set drifted")
    supplemental = plan.get("bTierSupplemental", {})
    if supplemental.get("comparators") != ["AlamofireImage"] or "excluded from A-tier" not in supplemental.get("policy", ""):
        errors.append("W7 V7 B-tier supplemental policy drifted")
    not_applicable = plan.get("notApplicable", {})
    if set(not_applicable) != {"Apple AsyncImage"} or "headless" not in not_applicable.get("Apple AsyncImage", ""):
        errors.append("W7 V7 must preserve AsyncImage as not applicable")
    if execution.get("originConcurrentServiceLimit") != 8:
        errors.append("W7 origin-owned service limit must remain eight")
    if execution.get("clientConcurrentFetchBudget") != 8:
        errors.append("W7 client fetch budget must remain eight")
    if plan.get("workloadID") != "W7-THOUSAND-CONCURRENT-V1":
        errors.append("unexpected W7 workload identity")
    subtraces = plan.get("subtraces", {})
    single = subtraces.get("singleFlightCancellation", {})
    priority = subtraces.get("priorityScheduling", {})
    if execution.get("logicalRequestCount") != 1000:
        errors.append("W7 must contain exactly 1000 logical requests")
    if single.get("logicalRequests") != 512 or priority.get("logicalRequests") != 488:
        errors.append("W7 subtraces must remain 512 + 488")
    if single.get("groups") * single.get("subscribersPerGroup") != 512:
        errors.append("single-flight group shape drifted")
    probe = priority.get("starvationProbe", {})
    balanced = priority.get("balancedRoundRobin", {})
    if priority.get("blockerRequests") != 8:
        errors.append("W7 V7 must keep eight blocker requests")
    if probe.get("olderBackgroundRequests") != 1 or probe.get("newerImmediateRequests") != 31:
        errors.append("W7 V7 starvation probe shape drifted")
    internal_bypass = probe.get("internalMaximumGrantBypasses")
    observable_bypass = probe.get("maximumObservableOriginStartBypasses")
    derived_observable = internal_bypass + execution.get("clientConcurrentFetchBudget", 0) - 1         if isinstance(internal_bypass, int) else None
    if internal_bypass != 8:
        errors.append("W7 V7 internal grant-bypass bound drifted")
    if observable_bypass != 15 or observable_bypass != derived_observable:
        errors.append("W7 V7 origin-start bound must equal 8 + client budget - 1 = 15")
    if probe.get("observableBoundDerivation") !=         "internalMaximumGrantBypasses + clientConcurrentFetchBudget - 1":
        errors.append("W7 V7 observable-bound derivation is missing")
    if balanced.get("requestsPerPriority") * 4 != 448:
        errors.append("W7 V7 balanced burst shape drifted")
    if balanced.get("submissionOrder") != "round-robin-background-utility-visible-immediate":
        errors.append("W7 V7 must keep round-robin balanced arrivals")
    if 8 + 1 + 31 + balanced.get("logicalRequests", 0) != 488:
        errors.append("W7 V7 priority subtrace no longer totals 488")
    if single.get("expectedCancelledSubscribers") != 256:
        errors.append("cancelled subscriber contract drifted")
    if single.get("expectedCompletedSubscribers") + priority.get("expectedCompletedSubscribers") != 744:
        errors.append("completed subscriber contract drifted")
    required = {
        "single-flight-origin-request-count",
        "p99-logical-latency",
        "peak-thread-count",
        "immediate-to-background-p95-ratio",
    }
    if set(plan.get("primaryEndpoints", {})) != required:
        errors.append("W7 primary endpoint set drifted")
    if claims.get("schemaVersion") != 7 or claims.get("registryID") != "FOVEA-W7-CONCURRENCY-CLAIMS-V7":
        errors.append("unexpected W7 claim registry identity")
    if claims.get("status") != "preregistered-after-v6-calibration-before-formal-results":
        errors.append("W7 V7 claim registry must remain preregistered")
    if claims.get("supersedes") != "Benchmarks/W7ConcurrencyLab/plans/claim-families-v6.json":
        errors.append("W7 V6 claim archive binding is missing")
    archived_claims = json.loads(
        (ROOT / "Benchmarks/W7ConcurrencyLab/plans/claim-families-v6.json").read_text()
    )
    if archived_claims.get("schemaVersion") != 6 or archived_claims.get("registryID") != "FOVEA-W7-CONCURRENCY-CLAIMS-V6":
        errors.append("archived W7 V6 claim identity drifted")
    efficiency = next(
        (family for family in claims.get("families", []) if family.get("id") == "W7.ConcurrentEfficiency"),
        None,
    )
    if not efficiency:
        errors.append("W7 efficiency claim family is missing")
    else:
        if efficiency.get("comparators") != [
            "Apple URLSession + URLCache + ImageIO", "Nuke", "Kingfisher", "SDWebImage", "PINRemoteImage"
        ]:
            errors.append("W7 A-tier efficiency comparator set drifted")
        if efficiency.get("bTierSupplemental") != ["AlamofireImage"]:
            errors.append("W7 B-tier supplemental claim boundary drifted")
        if efficiency.get("multiplicity") != "holm-within-a-tier-headless-family":
            errors.append("W7 multiplicity must remain within A-tier headless family")
    claim_endpoints = {
        endpoint
        for family in claims.get("families", [])
        for endpoint in family.get("primaryEndpoints", [])
    }
    if claim_endpoints != required:
        errors.append("W7 claim endpoints differ from plan")
    w7 = next((item for item in workloads.get("workloads", []) if item.get("id") == "W7"), None)
    if not w7 or w7.get("canonicalID") != plan.get("workloadID"):
        errors.append("W7 workload registry binding drifted")
    print(
        f"W7 concurrency plan: errors={len(errors)} "
        f"planSHA256:{canonical(plan)} claimsSHA256:{canonical(claims)}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
