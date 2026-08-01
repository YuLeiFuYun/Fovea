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

ROOT = Path(__file__).resolve().parents[1]
PLAN = ROOT / "Benchmarks/CacheLab/cache-plan.json"
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
        description="Analyze Cache Lab V2 with semantic stratification, paired bootstrap TOST, and Holm correction."
    )
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    source = args.input if args.input.is_absolute() else ROOT / args.input
    output = args.output if args.output.is_absolute() else ROOT / args.output
    data = json.loads(source.read_text())
    plan = json.loads(PLAN.read_text())
    claim_families = json.loads(CLAIM_FAMILIES.read_text())
    if data.get("schemaVersion") not in {2, 3} or data.get("planID") != "FOVEA-CACHE-LAB-V2":
        fail("unexpected Cache Lab V2 report identity")
    if plan.get("schemaVersion") != 2 or plan.get("planID") != data["planID"]:
        fail("Cache Lab report and preregistered plan differ")
    runs = data.get("runs")
    if not isinstance(runs, list) or not runs:
        fail("Cache Lab report contains no runs")
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

    comparisons: list[dict[str, Any]] = []
    for metric_index, (identifier, section, extractor, disk_primary_only) in enumerate(metric_specs):
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
    descriptive = descriptive_summary(runs, descriptive_specs)

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
    allowed = {"fovea-superior", "fovea-equivalent", "fovea-noninferior"}
    all_primary_noninferior = bool(comparisons) and all(
        item["classification"] in allowed for item in comparisons
    )
    formal = (
        data.get("executionMode") == "formal"
        and len(runs) >= int(plan["statistics"]["repetitions"])
        and not data.get("provisional", True)
    )
    fovea_identity_raw = data.get("sourceIdentity", {}).get("Fovea")
    try:
        fovea_identity = json.loads(fovea_identity_raw) if isinstance(fovea_identity_raw, str) else {}
    except json.JSONDecodeError:
        fovea_identity = {}
    source_identity_bound = (
        isinstance(fovea_identity.get("commit"), str)
        and len(fovea_identity["commit"]) == 40
        and isinstance(fovea_identity.get("sourceTreeDigest"), str)
        and len(fovea_identity["sourceTreeDigest"]) == 64
        and isinstance(fovea_identity.get("includesWorkingTreeChanges"), bool)
    )
    trusted_clean_source = source_identity_bound and not fovea_identity["includesWorkingTreeChanges"]
    expected_plan_digest = canonical_digest(plan)
    expected_claim_family_digest = canonical_digest(claim_families)
    claim_family_identity_bound = (
        data.get("schemaVersion") == 3
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
    best_claim_eligible = (
        statistical_performance_gate_passed
        and trusted_clean_source
        and claim_family_identity_bound
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
            (not source_identity_bound, "source-identity-invalid-or-unbound"),
            (source_identity_bound and not trusted_clean_source, "trusted-clean-source-evidence-missing"),
            (not claim_family_identity_bound, "claim-family-or-plan-digest-unbound"),
        ]
        if condition
    ]

    analysis = {
        "schemaVersion": 3,
        "planID": data["planID"],
        "executionMode": data["executionMode"],
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
        "sourceIdentity": fovea_identity,
        "sourceIdentityBound": source_identity_bound,
        "trustedCleanSource": trusted_clean_source,
        "experimentPlanDigest": data.get("experimentPlanDigest"),
        "expectedExperimentPlanDigest": expected_plan_digest,
        "claimFamilyDigest": data.get("claimFamilyDigest"),
        "expectedClaimFamilyDigest": expected_claim_family_digest,
        "claimFamilyIdentityBound": claim_family_identity_bound,
        "statisticalPerformanceGatePassed": statistical_performance_gate_passed,
        "comparisons": comparisons,
        "descriptiveMetrics": descriptive,
        "bestClaimEligible": best_claim_eligible,
        "bestClaimBlockedReasons": blocked_reasons,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(analysis, indent=2, sort_keys=True) + "\n")
    print(
        "Cache Lab V2 analysis: "
        f"runs={len(runs)} foveaFailures={len(fovea_failures)} "
        f"primaryComparatorFailures={len(primary_comparator_failures)} "
        f"inferior={len(inferior)} inconclusive={len(inconclusive)} "
        f"bestClaimEligible={str(best_claim_eligible).lower()}"
    )
    print(f"Artifact: {output.relative_to(ROOT)}")
    return 0 if not fovea_failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
