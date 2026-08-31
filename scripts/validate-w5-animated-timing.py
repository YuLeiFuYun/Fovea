#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
FIXTURE_MANIFEST = ROOT / "Benchmarks/ComparativeLab/Fixtures/animated-player-fixtures.json"
EXPECTED_WORKLOAD = "W5-ANIMATED-MEDIA-V1"
EXPECTED_ROLE = "PLAYER-TIMING"
EXPECTED_BUFFER_BYTES = 32 * 1_024 * 1_024
EXPECTED_INPUT_PATH = {
    "APNGKit": "encoded-native",
    "AnimatedImage": "encoded-native",
    "FLAnimatedImage": "encoded-native",
    "Gifu": "encoded-native",
    "Fovea": "synthetic-decoded-frames",
    "Kingfisher": "encoded-native",
    "PINRemoteImage": "encoded-native",
    "SDWebImage": "encoded-native",
}


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected JSON object")
    return value


def fixture(identifier: str) -> dict[str, Any]:
    manifest = load_json(FIXTURE_MANIFEST)
    if manifest.get("schemaVersion") != 1:
        raise ValueError("animated fixture manifest schema changed")
    matches = [item for item in manifest.get("fixtures", []) if item.get("id") == identifier]
    if len(matches) != 1:
        raise ValueError(f"{identifier} fixture must exist exactly once")
    return matches[0]


def validate_artifact(
    path: Path,
    *,
    expected_comparator: str | None = None,
    expected_fixture_id: str | None = None,
) -> dict[str, Any]:
    errors: list[str] = []
    data = load_json(path)
    artifact_fixture_id = data.get("fixtureID")
    if not isinstance(artifact_fixture_id, str):
        raise ValueError("fixtureID missing")
    if expected_fixture_id is not None and artifact_fixture_id != expected_fixture_id:
        raise ValueError(
            f"expected fixture {expected_fixture_id}, found {artifact_fixture_id}"
        )
    source = fixture(artifact_fixture_id)

    def require(condition: bool, message: str) -> None:
        if not condition:
            errors.append(message)

    comparator = data.get("comparator") or {}
    comparator_name = comparator.get("name")
    require(data.get("schemaVersion") == 1, "schemaVersion must be 1")
    require(data.get("measurementRole") == EXPECTED_ROLE, "measurementRole must be PLAYER-TIMING")
    require(data.get("workloadID") == EXPECTED_WORKLOAD, "workloadID must be W5-ANIMATED-MEDIA-V1")
    require(data.get("executionEnvironment") == "simulator", "structural artifact must be simulator")
    require(data.get("provisional") is True, "simulator artifact must remain provisional")
    require(isinstance(data.get("planID"), str) and bool(data["planID"]), "planID missing")
    require(data.get("fixtureID") == source["id"], "fixture ID mismatch")
    require(data.get("fixtureDigest") == source["sha256"], "fixture digest mismatch")
    require(data.get("maximumFrameBufferBytes") == EXPECTED_BUFFER_BYTES, "frame buffer policy mismatch")
    require(isinstance(data.get("maximumDisplayFramesPerSecond"), int) and data["maximumDisplayFramesPerSecond"] > 0, "maximum display FPS invalid")
    require(comparator_name in EXPECTED_INPUT_PATH, f"unsupported comparator identity: {comparator_name!r}")
    if expected_comparator is not None:
        require(comparator_name == expected_comparator, f"expected comparator {expected_comparator}, found {comparator_name}")
    if comparator_name in EXPECTED_INPUT_PATH:
        require(data.get("playerInputPath") == EXPECTED_INPUT_PATH[comparator_name], "player input path mismatch")
    require(isinstance(comparator.get("exactCommit"), str) and len(comparator["exactCommit"]) == 40, "comparator exact commit must be 40 hex")
    require(all(c in "0123456789abcdef" for c in str(comparator.get("exactCommit", ""))), "comparator exact commit must be lowercase hex")
    if comparator_name == "Fovea":
        require(comparator.get("includesWorkingTreeChanges") is True, "local Fovea calibration must bind dirty worktree")
        tree = comparator.get("sourceTreeDigest")
        require(isinstance(tree, str) and len(tree) == 64, "Fovea sourceTreeDigest missing")
    else:
        require(comparator.get("includesWorkingTreeChanges") is False, "external comparator must bind clean retained commit")

    require(data.get("nativeSourceFrameDurationsNanoseconds") == source["frameDurationsNanoseconds"], "native source durations differ from reference fixture")
    require(data.get("nativeSourceLoopCount") == source["loopCount"], "native source loop count differs from reference fixture")
    checks = data.get("checks") or []
    require(len(checks) >= 2, "required W5 checks missing")
    require(all(item.get("passed") is True for item in checks), "one or more W5 structural checks failed")

    presentation = data.get("presentation") or {}
    score = presentation.get("score") or {}
    observations = presentation.get("observations") or []
    timeline = presentation.get("timeline") or {}
    require(presentation.get("workloadID") == EXPECTED_WORKLOAD, "presentation workload mismatch")
    require(presentation.get("datasetDigest") == source["sha256"], "presentation dataset digest mismatch")
    require(timeline.get("frameDurationsNanoseconds") == source["frameDurationsNanoseconds"], "presentation timeline mismatch")
    require(len(observations) >= source["frameCount"], "insufficient source-frame observations")
    require(score.get("transitionCount") == source["frameCount"], "one full source loop must contain exactly frameCount transitions")
    require(score.get("observedSkippedSourceFrameCount") == 0, "source-frame skips are not admissible in structural calibration")
    require(score.get("frameOrderViolationCount") == 0, "frame-order violation detected")
    require(isinstance(score.get("p95AbsoluteTimingErrorNanoseconds"), int), "p95 timing error missing")
    require(isinstance(presentation.get("startupLatencyNanoseconds"), int), "startup latency missing")
    require((observations[0].get("elapsedNanoseconds") if observations else None) == 0, "first normalized observation must anchor elapsed time zero")

    if errors:
        raise ValueError("; ".join(errors))
    return {
        "comparator": comparator_name,
        "fixtureID": source["id"],
        "inputPath": data["playerInputPath"],
        "observationCount": len(observations),
        "transitionCount": score["transitionCount"],
        "p95AbsoluteTimingErrorNanoseconds": score["p95AbsoluteTimingErrorNanoseconds"],
        "missedDeadlineCount": score["missedDeadlineCount"],
        "startupLatencyNanoseconds": presentation["startupLatencyNanoseconds"],
        "provisional": True,
        "claimBoundary": "structural-simulator-calibration-no-ranking",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--comparator", choices=sorted(EXPECTED_INPUT_PATH))
    parser.add_argument("--fixture")
    args = parser.parse_args()
    try:
        summary = validate_artifact(
            args.artifact,
            expected_comparator=args.comparator,
            expected_fixture_id=args.fixture,
        )
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"W5 animated timing artifact invalid: {error}")
        return 1
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
