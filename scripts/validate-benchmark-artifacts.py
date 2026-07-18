#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import Any


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def require_nonnegative(summary: dict[str, Any], names: list[str]) -> None:
    for name in names:
        require(name in summary, f"summary missing {name}")
        require(isinstance(summary[name], (int, float)), f"summary {name} must be numeric")
        require(summary[name] >= 0, f"summary {name} must be nonnegative")


def validate_common(data: dict[str, Any]) -> str:
    require(data.get("schemaVersion") == 1, "schemaVersion must be 1")
    for name in (
        "workloadID",
        "profileID",
        "generatedAt",
        "platform",
        "architecture",
        "operatingSystem",
        "verifiedCommit",
    ):
        require(isinstance(data.get(name), str) and data[name], f"missing {name}")
    return data["workloadID"]


def validate_w1_w2(data: dict[str, Any], workload: str) -> None:
    require(isinstance(data.get("cacheState"), str) and data["cacheState"], "missing cacheState")
    require(data.get("datasetLogicalItemCount", 0) > 0, "datasetLogicalItemCount must be positive")
    require(data.get("uniqueResourceCount", 0) > 0, "uniqueResourceCount must be positive")
    require(isinstance(data.get("sources"), list) and data["sources"], "sources must be non-empty")
    require(isinstance(data.get("targets"), list) and data["targets"], "targets must be non-empty")
    require(isinstance(data.get("trace"), list) and data["trace"], "trace must be non-empty")
    require(
        isinstance(data.get("diagnostics"), list) and data["diagnostics"],
        "diagnostics must be non-empty",
    )

    summary = data.get("summary")
    require(isinstance(summary, dict), "summary must be an object")
    require_nonnegative(
        summary,
        [
            "attemptedLoads",
            "completedLoads",
            "cancelledLoads",
            "failedLoads",
            "decodedMegapixels",
            "sourceMegapixelsObserved",
            "networkRequestCount",
            "networkBytes",
            "duplicateRequestCount",
            "singleFlightJoinCount",
            "fetchCancellationCount",
            "originalEncodedHitCount",
            "renderedMemoryHitCount",
            "droppedDiagnosticEventCount",
        ],
    )
    require(
        summary["attemptedLoads"]
        == summary["completedLoads"] + summary["cancelledLoads"] + summary["failedLoads"],
        "load outcome counts do not add up",
    )
    require(summary["failedLoads"] == 0, "smoke artifact contains failed loads")
    require(summary["droppedDiagnosticEventCount"] == 0, "diagnostics were dropped")

    if workload == "W1-Feed-Scroll-Smoke":
        require(data["datasetLogicalItemCount"] == 1000, "W1 must declare 1000 logical items")
        require(summary["cancelledLoads"] > 0, "W1 must exercise cancellation")
        require(summary["singleFlightJoinCount"] > 0, "W1 must exercise single-flight joins")
        require(summary["renderedMemoryHitCount"] > 0, "W1 must exercise memory hits")
    elif workload == "W2-Detail-Hero-Smoke":
        source_pixels = [source["pixelWidth"] * source["pixelHeight"] for source in data["sources"]]
        require(source_pixels == [12_000_000, 24_000_000, 48_000_000], "W2 source corpus mismatch")
        require(summary["networkRequestCount"] == 3, "W2 must fetch each source exactly once")
        require(summary["originalEncodedHitCount"] >= 6, "W2 must exercise OriginalEncoded hits")
        for event in data["trace"]:
            if event.get("category") != "hero-load" or event.get("outcome") != "completed":
                continue
            target = event.get("target") or {}
            decoded = event.get("decodedPixelCount")
            require(isinstance(decoded, int), "W2 completed event missing decodedPixelCount")
            require(
                decoded <= target.get("width", 0) * target.get("height", 0),
                "W2 decoded pixels exceed target bounding box",
            )
    else:
        raise ValueError(f"unexpected performance workloadID {workload}")


def validate_w3(data: dict[str, Any]) -> None:
    cases = data.get("cases")
    diagnostics = data.get("diagnostics")
    summary = data.get("summary")
    require(isinstance(cases, list) and cases, "W3 cases must be non-empty")
    require(isinstance(diagnostics, list) and diagnostics, "W3 diagnostics must be non-empty")
    require(isinstance(summary, dict), "W3 summary must be an object")
    for case in cases:
        require(isinstance(case, dict), "W3 case must be an object")
        require(isinstance(case.get("identifier"), str) and case["identifier"], "W3 case missing identifier")
        require(case.get("passed") is True, f"W3 case failed: {case.get('identifier')}")
    violation_fields = [
        "crossAccountPixelLeakCount",
        "crossAccountMetadataCouplingCount",
        "noStoreReusableWriteCount",
        "logoutResidueCount",
        "crossOriginAuthorizationLeakCount",
        "revokedCommitResidueCount",
        "sensitiveDiagnosticLeakCount",
    ]
    require_nonnegative(summary, violation_fields + ["networkRequestCount"])
    for field in violation_fields:
        require(summary[field] == 0, f"W3 violation {field}={summary[field]}")
    require(summary["networkRequestCount"] >= 5, "W3 did not execute all network scenarios")


def validate(path: Path) -> tuple[str, str]:
    data = json.loads(path.read_text())
    workload = validate_common(data)
    if workload == "W3-Auth-Gallery-Smoke":
        validate_w3(data)
    else:
        validate_w1_w2(data, workload)
    return workload, hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    paths = [Path(argument) for argument in sys.argv[1:]]
    if not paths:
        paths = sorted(Path(".artifacts/benchmarks").glob("*.json"))
    if not paths:
        print("No benchmark artifacts found", file=sys.stderr)
        return 1

    seen: set[str] = set()
    try:
        for path in paths:
            workload, digest = validate(path)
            require(workload not in seen, f"duplicate workload artifact {workload}")
            seen.add(workload)
            print(f"Benchmark artifact valid: {path} sha256:{digest}")
        require(
            {
                "W1-Feed-Scroll-Smoke",
                "W2-Detail-Hero-Smoke",
                "W3-Auth-Gallery-Smoke",
            }.issubset(seen),
            "W1, W2, and W3 artifacts are required",
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Benchmark artifact validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
