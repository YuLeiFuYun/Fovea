#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import statistics
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any, Callable

from cache_lab_host_monitor import validate_host_execution_evidence

ROOT = Path(__file__).resolve().parents[1]
PLAN = ROOT / "Benchmarks/CacheLab/cache-plan.json"
ARCHIVED_PLAN_V3 = ROOT / "Benchmarks/CacheLab/plans/cache-plan-v3.json"
ARCHIVED_PLAN_V2 = ROOT / "Benchmarks/CacheLab/plans/cache-plan-v2.json"
ARCHIVED_CLAIMS_V3 = ROOT / "Benchmarks/CacheLab/plans/statistical-claim-families-cachelab-v3.json"
ARCHIVED_CLAIMS_V2 = ROOT / "Benchmarks/CacheLab/plans/statistical-claim-families-cachelab-v2.json"
CLAIM_FAMILIES = ROOT / "Benchmarks/statistical-claim-families.json"
DEFAULT_INPUT = ROOT / ".artifacts/cache-lab/raw-results.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/cache-lab/analysis.json"
BOOTSTRAP_ITERATIONS = 10_000
ALPHA = 0.05


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def canonical_digest(value: object) -> str:
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def percentile(values: list[float], q: float) -> float:
    if not values:
        return math.nan
    ordered = sorted(values)
    position = (len(ordered) - 1) * q
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] * (1 - fraction) + ordered[upper] * fraction


def empirical_probability(count: int, total: int) -> float:
    return (count + 1) / (total + 1)


def oriented_difference(
    fovea: float,
    comparator: float,
    *,
    direction: str,
    scale: str,
) -> float:
    if scale == "absolute-difference":
        return fovea - comparator if direction == "higher" else comparator - fovea
    if scale == "log-ratio":
        if fovea <= 0 or comparator <= 0:
            fail("log-ratio metrics require strictly positive samples")
        return math.log(fovea / comparator) if direction == "higher" else math.log(comparator / fovea)
    fail(f"unsupported decision scale: {scale}")
    raise AssertionError("unreachable")


def oriented_margin(value: float, scale: str) -> float:
    return value if scale == "absolute-difference" else math.log1p(value)


def bootstrap_comparison(
    fovea: list[float],
    comparator: list[float],
    *,
    rule: dict[str, Any],
    seed: int,
) -> dict[str, Any]:
    if len(fovea) != len(comparator) or not fovea:
        fail("paired metric series are incomplete")
    oriented = [
        oriented_difference(
            a,
            b,
            direction=rule["direction"],
            scale=rule["scale"],
        )
        for a, b in zip(fovea, comparator, strict=True)
    ]
    rng = random.Random(seed)
    samples: list[float] = []
    for _ in range(BOOTSTRAP_ITERATIONS):
        draw = [oriented[rng.randrange(len(oriented))] for _ in oriented]
        samples.append(statistics.median(draw))

    estimate = statistics.median(oriented)
    lower = percentile(samples, 0.025)
    upper = percentile(samples, 0.975)
    equivalence = oriented_margin(float(rule["equivalenceMargin"]), rule["scale"])
    noninferiority = oriented_margin(float(rule["nonInferiorityMargin"]), rule["scale"])
    superiority = oriented_margin(float(rule["superiorityMargin"]), rule["scale"])
    dominance = oriented_margin(float(rule["dominanceMargin"]), rule["scale"])
    total = len(samples)
    def boundary_p_value(boundary: float, *, alternative: str, salt: int) -> float:
        null_centered = [value - estimate + boundary for value in oriented]
        null_rng = random.Random(seed + salt)
        extreme = 0
        for _ in range(BOOTSTRAP_ITERATIONS):
            draw = [null_centered[null_rng.randrange(len(null_centered))] for _ in null_centered]
            statistic = statistics.median(draw)
            if alternative == "greater":
                extreme += statistic >= estimate
            else:
                extreme += statistic <= estimate
        return empirical_probability(extreme, BOOTSTRAP_ITERATIONS)

    raw_p = {
        "superiority": boundary_p_value(superiority, alternative="greater", salt=11),
        "noninferiority": boundary_p_value(-noninferiority, alternative="greater", salt=23),
        "equivalenceLower": boundary_p_value(-equivalence, alternative="greater", salt=37),
        "equivalenceUpper": boundary_p_value(equivalence, alternative="less", salt=53),
        "inferiority": boundary_p_value(-noninferiority, alternative="less", salt=71),
    }
    result: dict[str, Any] = {
        "orientedMedianDifference": estimate,
        "confidenceInterval95": [lower, upper],
        "decisionScale": rule["scale"],
        "direction": rule["direction"],
        "equivalenceBoundOriented": equivalence,
        "nonInferiorityBoundOriented": noninferiority,
        "superiorityBoundOriented": superiority,
        "dominanceBoundOriented": dominance,
        "rawPValues": raw_p,
        "adjustedPValues": {},
        "classification": "pending-holm-correction",
        "foveaMedian": statistics.median(fovea),
        "comparatorMedian": statistics.median(comparator),
        "sampleCount": len(fovea),
    }
    if rule["scale"] == "log-ratio":
        result["orientedMedianRatio"] = math.exp(estimate)
        result["confidenceRatio95"] = [math.exp(lower), math.exp(upper)]
    return result


def holm_adjust(values: list[float]) -> list[float]:
    if not values:
        return []
    ordered = sorted(enumerate(values), key=lambda item: item[1])
    adjusted = [1.0] * len(values)
    running = 0.0
    count = len(values)
    for rank, (index, value) in enumerate(ordered):
        candidate = min(1.0, (count - rank) * value)
        running = max(running, candidate)
        adjusted[index] = running
    return adjusted


def apply_holm_and_classify(comparisons: list[dict[str, Any]]) -> None:
    grouped: dict[tuple[str, str], list[int]] = defaultdict(list)
    for index, comparison in enumerate(comparisons):
        for test_name in comparison["rawPValues"]:
            grouped[(comparison["metric"], test_name)].append(index)

    for (_, test_name), indices in grouped.items():
        adjusted = holm_adjust(
            [float(comparisons[index]["rawPValues"][test_name]) for index in indices]
        )
        for index, value in zip(indices, adjusted, strict=True):
            comparisons[index]["adjustedPValues"][test_name] = value

    for comparison in comparisons:
        adjusted = comparison["adjustedPValues"]
        estimate = float(comparison["orientedMedianDifference"])
        superiority = float(comparison["superiorityBoundOriented"])
        noninferiority = float(comparison["nonInferiorityBoundOriented"])
        if adjusted["superiority"] < ALPHA and estimate > superiority:
            classification = "fovea-superior"
        elif adjusted["equivalenceLower"] < ALPHA and adjusted["equivalenceUpper"] < ALPHA:
            classification = "fovea-equivalent"
        elif adjusted["noninferiority"] < ALPHA:
            classification = "fovea-noninferior"
        elif adjusted["inferiority"] < ALPHA and estimate < -noninferiority:
            classification = "fovea-inferior"
        else:
            classification = "inconclusive"
        comparison["classification"] = classification
        comparison["dominanceSatisfied"] = (
            adjusted["superiority"] < ALPHA
            and float(comparison["confidenceInterval95"][0])
                > float(comparison["dominanceBoundOriented"])
        )


def collect(
    runs: list[dict[str, Any]],
    section: str,
    contestant_key: str,
    metric: Callable[[dict[str, Any]], float],
    *,
    predicate: Callable[[dict[str, Any]], bool] | None = None,
) -> dict[str, list[float]]:
    result: dict[str, list[float]] = {}
    expected_names: set[str] | None = None
    for run in sorted(runs, key=lambda item: item["repetition"]):
        per_run: dict[str, float] = {}
        for record in run[section]:
            if predicate is not None and not predicate(record):
                continue
            name = record[contestant_key]
            if name in per_run:
                fail(f"duplicate {section} contestant in repetition")
            per_run[name] = metric(record)
        names = set(per_run)
        if expected_names is None:
            expected_names = names
        elif names != expected_names:
            fail(f"incomplete paired contestants for {section}: expected={sorted(expected_names)} observed={sorted(names)}")
        for name, value in per_run.items():
            result.setdefault(name, []).append(value)
    return result


def all_checks(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    failures: list[dict[str, Any]] = []
    for record in records:
        for check in record["checks"]:
            if not check["passed"]:
                failures.append(
                    {
                        "contestant": record["contestant"],
                        "check": check["identifier"],
                        "value": check["value"],
                        "rankingRole": record.get("rankingRole"),
                        "semanticGroup": record.get("semanticGroup"),
                    }
                )
    return failures


def descriptive_summary(
    runs: list[dict[str, Any]],
    metric_specs: list[tuple[str, str, Callable[[dict[str, Any]], float]]],
) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    for identifier, section, extractor in metric_specs:
        series = collect(
            runs,
            section,
            "contestant",
            extractor,
            predicate=lambda record: record.get("rankingRole") == "descriptive",
        )
        for contestant, values in sorted(series.items()):
            output.append(
                {
                    "metric": identifier,
                    "contestant": contestant,
                    "median": statistics.median(values),
                    "sampleCount": len(values),
                    "rankingRole": "descriptive",
                    "reason": "semantic-profile-differs-from-fovea-primary-disk-contract",
                }
            )
    return output


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Analyze versioned Cache Lab evidence with semantic stratification, paired bootstrap TOST, and Holm correction."
    )
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    source = args.input if args.input.is_absolute() else ROOT / args.input
    output = args.output if args.output.is_absolute() else ROOT / args.output
    data = json.loads(source.read_text())
    plan_id = data.get("planID")
    plan_paths = {
        "FOVEA-CACHE-LAB-V2": ARCHIVED_PLAN_V2,
        "FOVEA-CACHE-LAB-V3": ARCHIVED_PLAN_V3,
        "FOVEA-CACHE-LAB-V4": PLAN,
    }
    claim_paths = {
        "FOVEA-CACHE-LAB-V2": ARCHIVED_CLAIMS_V2,
        "FOVEA-CACHE-LAB-V3": ARCHIVED_CLAIMS_V3,
        "FOVEA-CACHE-LAB-V4": CLAIM_FAMILIES,
    }
    plan_path = plan_paths.get(plan_id)
    if data.get("schemaVersion") not in {2, 3, 4} or plan_path is None:
        fail("unexpected Cache Lab report identity")
    plan = json.loads(plan_path.read_text())
    claim_families = json.loads(claim_paths[plan_id].read_text())
    expected_plan_schema = {
        "FOVEA-CACHE-LAB-V2": 2,
        "FOVEA-CACHE-LAB-V3": 3,
        "FOVEA-CACHE-LAB-V4": 4,
    }[plan_id]
    if plan.get("schemaVersion") != expected_plan_schema or plan.get("planID") != plan_id:
        fail("Cache Lab report and versioned preregistered plan differ")
    runs = data.get("runs")
    if not isinstance(runs, list) or not runs:
        fail("Cache Lab report contains no runs")
    scope = data.get("benchmarkScope", "all")
    if scope not in {"all", "memory", "hot", "concurrent"}:
        fail("unsupported Cache Lab benchmark scope")
    if data.get("executionMode") == "formal" and scope != "all":
        fail("formal Cache Lab evidence must use the full benchmark scope")
    decision_rules = plan.get("metricDecisionRules", {})

    metric_specs: list[tuple[str, str, Callable[[dict[str, Any]], float], bool]] = [
        (
            "memory-hot-scan-hit-rate",
            "memoryHotScan",
            lambda r: float(r["hotHits"]) / float(r["hotObjectCount"]),
            False,
        ),
        (
            "memory-hot-scan-throughput",
            "memoryHotScan",
            lambda r: float(r["operations"]) * 1_000_000_000 / float(r["durationNanoseconds"]),
            False,
        ),
        (
            "memory-hot-scan-p99-latency",
            "memoryHotScan",
            lambda r: float(r["p99OperationNanoseconds"]),
            False,
        ),
        (
            "memory-concurrent-throughput",
            "memoryConcurrent",
            lambda r: float(r["operations"]) * 1_000_000_000 / float(r["durationNanoseconds"]),
            False,
        ),
        (
            "memory-concurrent-p99-latency",
            "memoryConcurrent",
            lambda r: float(r["p99WorkerOperationNanoseconds"]),
            False,
        ),
        (
            "disk-write-throughput",
            "diskMixed",
            lambda r: float(r["totalBytes"]) * 1_000_000_000 / float(r["writeDurationNanoseconds"]),
            True,
        ),
        (
            "disk-read-throughput",
            "diskMixed",
            lambda r: float(r["totalBytes"]) * 1_000_000_000 / float(r["readDurationNanoseconds"]),
            True,
        ),
        (
            "disk-p99-read-latency",
            "diskMixed",
            lambda r: float(r["p99ReadNanoseconds"]),
            True,
        ),
    ]

    applicable_metric_specs = [
        spec
        for spec in metric_specs
        if scope == "all"
        or (scope == "memory" and not spec[3])
        or (scope == "hot" and spec[1] == "memoryHotScan")
        or (scope == "concurrent" and spec[1] == "memoryConcurrent")
    ]
    comparisons: list[dict[str, Any]] = []
    for metric_index, (identifier, section, extractor, disk_primary_only) in enumerate(applicable_metric_specs):
        rule = decision_rules.get(identifier)
        if not isinstance(rule, dict):
            fail(f"metric {identifier} lacks a preregistered decision rule")
        predicate = None
        if disk_primary_only:
            predicate = lambda record: (
                record.get("rankingRole") == "primary"
                and record.get("semanticGroup") == "content-validated-durable-commit"
                and record.get("durabilityLevel") == "D5"
            )
        series = collect(runs, section, "contestant", extractor, predicate=predicate)
        fovea = series.get("Fovea")
        if not fovea:
            fail(f"metric {identifier} has no Fovea samples")
        for name in sorted(set(series) - {"Fovea"}):
            result = bootstrap_comparison(
                fovea,
                series[name],
                rule=rule,
                seed=20260725 + metric_index * 101 + sum(name.encode()),
            )
            result.update(
                {
                    "metric": identifier,
                    "comparator": name,
                    "semanticGroup": (
                        "content-validated-durable-commit" if disk_primary_only else "memory-common-contract"
                    ),
                }
            )
            comparisons.append(result)
    apply_holm_and_classify(comparisons)

    descriptive_specs = [
        ("disk-write-throughput", "diskMixed", metric_specs[5][2]),
        ("disk-read-throughput", "diskMixed", metric_specs[6][2]),
        ("disk-p99-read-latency", "diskMixed", metric_specs[7][2]),
    ]
    descriptive = descriptive_summary(runs, descriptive_specs) if scope == "all" else []

    memory_records = [
        record
        for run in runs
        for section in ("memoryHotScan", "memoryConcurrent")
        for record in run[section]
    ]
    disk_correctness = data.get("diskCorrectness", [])
    mixed_records = [record for run in runs for record in run["diskMixed"]]
    all_failures = all_checks(memory_records) + all_checks(disk_correctness) + all_checks(mixed_records)
    fovea_failures = [item for item in all_failures if item["contestant"] == "Fovea"]
    primary_comparator_failures = [
        item
        for item in all_failures
        if item["contestant"] != "Fovea" and item.get("rankingRole") == "primary"
    ]
    descriptive_failures = [
        item
        for item in all_failures
        if item["contestant"] != "Fovea" and item.get("rankingRole") == "descriptive"
    ]

    inferior = [
        {"metric": item["metric"], "comparator": item["comparator"]}
        for item in comparisons
        if item["classification"] == "fovea-inferior"
    ]
    inconclusive = [
        {"metric": item["metric"], "comparator": item["comparator"]}
        for item in comparisons
        if item["classification"] == "inconclusive"
    ]
    superior = [
        {"metric": item["metric"], "comparator": item["comparator"]}
        for item in comparisons
        if item["classification"] == "fovea-superior"
    ]
    dominance_failures = [
        {
            "metric": item["metric"],
            "comparator": item["comparator"],
            "classification": item["classification"],
            "confidenceLowerBound": item["confidenceInterval95"][0],
            "requiredDominanceBound": item["dominanceBoundOriented"],
        }
        for item in comparisons
        if not item.get("dominanceSatisfied", False)
    ]
    allowed = {"fovea-superior", "fovea-equivalent", "fovea-noninferior"}
    all_primary_noninferior = bool(comparisons) and all(
        item["classification"] in allowed for item in comparisons
    )
    formal = (
        data.get("executionMode") == "formal"
        and len(runs) >= int(plan["statistics"]["repetitions"])
        and not data.get("provisional", True)
    )
    def parsed_source_identity(component: str) -> dict[str, Any]:
        raw = data.get("sourceIdentity", {}).get(component)
        try:
            return json.loads(raw) if isinstance(raw, str) else {}
        except json.JSONDecodeError:
            return {}

    def valid_source_identity(identity: dict[str, Any]) -> bool:
        return (
            isinstance(identity.get("commit"), str)
            and len(identity["commit"]) == 40
            and isinstance(identity.get("sourceTreeDigest"), str)
            and len(identity["sourceTreeDigest"]) == 64
            and isinstance(identity.get("includesWorkingTreeChanges"), bool)
            and isinstance(identity.get("dependencyMode"), str)
        )

    host_policy = plan.get("hostExecutionPolicy", {})

    fovea_identity = parsed_source_identity("Fovea")
    akashic_identity = parsed_source_identity("Akashic")
    component_source_identities = {
        "Fovea": fovea_identity,
        "Akashic": akashic_identity,
    }
    source_identity_bound = (
        data.get("schemaVersion") == 4
        and valid_source_identity(fovea_identity)
        and valid_source_identity(akashic_identity)
    )
    source_resolution_bound = (
        source_identity_bound
        and fovea_identity.get("dependencyMode") == "root-worktree"
        and akashic_identity.get("dependencyMode") == "source-control-checkout"
        and akashic_identity.get("declaredRevision") == akashic_identity.get("commit")
    )
    trusted_clean_source = (
        source_resolution_bound
        and not fovea_identity["includesWorkingTreeChanges"]
        and not akashic_identity["includesWorkingTreeChanges"]
    )
    host_execution_evidence = data.get("hostExecutionEvidence")
    host_execution_evidence_bound, quiescent_host_bound = (
        validate_host_execution_evidence(
            host_execution_evidence,
            policy=host_policy,
            formal=formal,
            expected_repetitions=int(plan["statistics"]["repetitions"]),
        )
    )
    expected_plan_digest = canonical_digest(plan)
    expected_claim_family_digest = canonical_digest(claim_families)
    claim_family_identity_bound = (
        data.get("schemaVersion") == 4
        and data.get("experimentPlanDigest") == expected_plan_digest
        and data.get("claimFamilyDigest") == expected_claim_family_digest
    )
    statistical_performance_gate_passed = (
        formal
        and not fovea_failures
        and not primary_comparator_failures
        and all_primary_noninferior
        and bool(superior)
    )
    dominance_performance_gate_passed = (
        formal
        and not fovea_failures
        and not primary_comparator_failures
        and bool(comparisons)
        and not dominance_failures
    )
    best_claim_eligible = (
        dominance_performance_gate_passed
        and trusted_clean_source
        and claim_family_identity_bound
        and quiescent_host_bound
    )
    blocked_reasons = [
        reason
        for condition, reason in [
            (not formal, "formal-twenty-run-evidence-missing"),
            (bool(fovea_failures), "fovea-correctness-failure"),
            (bool(primary_comparator_failures), "primary-comparator-correctness-failure"),
            (bool(inferior), "fovea-inferior-on-applicable-primary-metric"),
            (bool(inconclusive), "primary-metric-evidence-inconclusive"),
            (not superior, "no-practically-meaningful-superiority-demonstrated"),
            (bool(dominance_failures), "not-all-primary-endpoints-meet-substantial-dominance-margin"),
            (not source_identity_bound, "component-source-identity-invalid-or-unbound"),
            (source_identity_bound and not source_resolution_bound, "dependency-resolution-untrusted-or-edited"),
            (source_resolution_bound and not trusted_clean_source, "trusted-clean-source-evidence-missing"),
            (not host_execution_evidence_bound, "benchmark-host-evidence-invalid-or-unbound"),
            (host_execution_evidence_bound and not quiescent_host_bound, "benchmark-host-contaminated-or-not-quiescent"),
            (not claim_family_identity_bound, "claim-family-or-plan-digest-unbound"),
        ]
        if condition
    ]

    analysis = {
        "schemaVersion": 4,
        "planID": data["planID"],
        "executionMode": data["executionMode"],
        "benchmarkScope": scope,
        "provisional": data.get("provisional", True),
        "runCount": len(runs),
        "bootstrapIterations": BOOTSTRAP_ITERATIONS,
        "confidenceLevel": 0.95,
        "equivalenceMethod": "paired-bootstrap-TOST",
        "multipleComparisonCorrection": "Holm-within-metric-family",
        "foveaCorrectnessFailures": fovea_failures,
        "primaryComparatorCorrectnessFailures": primary_comparator_failures,
        "descriptiveComparatorCorrectnessFailures": descriptive_failures,
        "statisticallyInferiorMetrics": inferior,
        "inconclusiveMetrics": inconclusive,
        "meaningfullySuperiorMetrics": superior,
        "dominanceFailures": dominance_failures,
        "sourceIdentity": fovea_identity,
        "componentSourceIdentities": component_source_identities,
        "sourceIdentityBound": source_identity_bound,
        "sourceResolutionBound": source_resolution_bound,
        "trustedCleanSource": trusted_clean_source,
        "hostExecutionEvidence": host_execution_evidence,
        "hostExecutionEvidenceBound": host_execution_evidence_bound,
        "quiescentHostBound": quiescent_host_bound,
        "experimentPlanDigest": data.get("experimentPlanDigest"),
        "expectedExperimentPlanDigest": expected_plan_digest,
        "claimFamilyDigest": data.get("claimFamilyDigest"),
        "expectedClaimFamilyDigest": expected_claim_family_digest,
        "claimFamilyIdentityBound": claim_family_identity_bound,
        "statisticalPerformanceGatePassed": statistical_performance_gate_passed,
        "dominancePerformanceGatePassed": dominance_performance_gate_passed,
        "comparisons": comparisons,
        "descriptiveMetrics": descriptive,
        "bestClaimEligible": best_claim_eligible,
        "bestClaimBlockedReasons": blocked_reasons,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(analysis, indent=2, sort_keys=True) + "\n")
    print(
        f"Cache Lab {data['planID']} analysis: "
        f"runs={len(runs)} foveaFailures={len(fovea_failures)} "
        f"primaryComparatorFailures={len(primary_comparator_failures)} "
        f"inferior={len(inferior)} inconclusive={len(inconclusive)} "
        f"dominanceFailures={len(dominance_failures)} "
        f"bestClaimEligible={str(best_claim_eligible).lower()}"
    )
    try:
        artifact_display = output.relative_to(ROOT)
    except ValueError:
        artifact_display = output
    print(f"Artifact: {artifact_display}")
    return 0 if not fovea_failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
