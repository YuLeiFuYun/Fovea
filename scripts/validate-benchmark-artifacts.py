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


def validate(path: Path) -> str:
    data = json.loads(path.read_text())
    require(data.get("schemaVersion") == 1, "schemaVersion must be 1")
    for name in (
        "workloadID",
        "profileID",
        "generatedAt",
        "platform",
        "architecture",
        "operatingSystem",
        "verifiedCommit",
        "cacheState",
    ):
        require(isinstance(data.get(name), str) and data[name], f"missing {name}")
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

    workload = data["workloadID"]
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
        raise ValueError(f"unexpected workloadID {workload}")

    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return digest


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
            digest = validate(path)
            workload = json.loads(path.read_text())["workloadID"]
            require(workload not in seen, f"duplicate workload artifact {workload}")
            seen.add(workload)
            print(f"Benchmark artifact valid: {path} sha256:{digest}")
        require(
            {"W1-Feed-Scroll-Smoke", "W2-Detail-Hero-Smoke"}.issubset(seen),
            "both W1 and W2 artifacts are required",
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Benchmark artifact validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
