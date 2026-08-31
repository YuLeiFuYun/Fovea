#!/usr/bin/env python3
"""Capture paired physical-Mac AppKit callback-timing evidence for two Fovea schedulers."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = ROOT / ".artifacts/performance/w5-appkit-callback-timing-physical-v1"
FIXED_PAIR_COUNT = 6
MODES = ("external", "deadline")
CONTROL = {
    "external": ("platform-default", "external-presentation-ticks"),
    "deadline": ("automatic-deadline", "automatic-deadline-loop"),
}


def run(command: list[str], *, env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and completed.returncode != 0:
        raise RuntimeError(
            f"command failed ({completed.returncode}): {' '.join(command)}\n"
            + completed.stdout
            + completed.stderr
        )
    return completed


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_identity(path: pathlib.Path) -> dict[str, object]:
    data = path.read_bytes()
    return {
        "path": str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path),
        "byteCount": len(data),
        "sha256": sha256_bytes(data),
    }


def git_identity() -> dict[str, object]:
    head = run(["git", "rev-parse", "HEAD"]).stdout.strip()
    dirty = bool(run(["git", "status", "--porcelain=v1"]).stdout.strip())
    digest = hashlib.sha256()
    digest.update(b"fovea-worktree-v1\0" + head.encode())
    digest.update(
        subprocess.run(
            ["git", "diff", "--binary", "HEAD"],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            check=True,
        ).stdout
    )
    untracked = run(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"]
    ).stdout.split("\0")
    for relative in sorted(item for item in untracked if item):
        path = ROOT / relative
        if path.is_file() and not path.is_symlink():
            digest.update(relative.encode() + b"\0" + path.read_bytes() + b"\0")
    return {
        "commit": head,
        "sourceTreeDigest": digest.hexdigest(),
        "includesWorkingTreeChanges": dirty,
    }


def percentile(values: list[int], numerator: int) -> int | None:
    if not values:
        return None
    ordered = sorted(values)
    rank = (len(ordered) * numerator + 99) // 100
    return ordered[max(0, rank - 1)]


def frame_starts(durations: list[int]) -> tuple[list[int], int]:
    starts: list[int] = []
    total = 0
    for duration in durations:
        starts.append(total)
        total += duration
    return starts, total


def frame_index_at(starts: list[int], elapsed_in_loop: int) -> int:
    lower = 0
    upper = len(starts)
    while lower < upper:
        middle = lower + (upper - lower) // 2
        if starts[middle] <= elapsed_in_loop:
            lower = middle + 1
        else:
            upper = middle
    return max(0, lower - 1)


def normalize_phase(durations: list[int], observations: list[dict[str, int]]) -> tuple[list[int], list[dict[str, int]]]:
    phase = observations[0]["frameIndex"]
    if phase == 0:
        return durations, observations
    rotated = durations[phase:] + durations[:phase]
    count = len(durations)
    normalized = [
        {
            "sequence": item["sequence"],
            "elapsedNanoseconds": item["elapsedNanoseconds"],
            "frameIndex": (item["frameIndex"] - phase + count) % count,
        }
        for item in observations
    ]
    return rotated, normalized


def score_report(report: dict[str, Any], tolerance: int) -> dict[str, Any]:
    durations = [int(value) for value in report["frameDurationsNanoseconds"]]
    observations = [dict(item) for item in report["observations"]]
    durations, observations = normalize_phase(durations, observations)
    starts, total = frame_starts(durations)
    count = len(durations)
    previous_elapsed = 0
    previous_frame = 0
    observed_ordinal = 0
    transition_errors: list[int] = []
    transition_count = 0
    mismatch = 0
    stale = 0
    ahead = 0
    order_violations = 0
    skipped = 0
    missed = 0
    early = 0
    max_behind = 0
    max_ahead = 0

    for offset, observation in enumerate(observations):
        elapsed = int(observation["elapsedNanoseconds"])
        frame = int(observation["frameIndex"])
        if int(observation["sequence"]) != offset or not (0 <= frame < count):
            raise ValueError("invalid callback observation identity")
        if offset == 0:
            if elapsed != 0:
                raise ValueError("first callback observation must be normalized to zero")
        elif elapsed <= previous_elapsed:
            raise ValueError("callback observations must be strictly monotonic")

        loop = elapsed // total
        expected_frame = frame_index_at(starts, elapsed % total)
        expected_ordinal = loop * count + expected_frame

        if offset > 0 and frame != previous_frame:
            delta = frame - previous_frame if frame > previous_frame else count - previous_frame + frame
            observed_ordinal += delta
            transition_count += 1
            if delta > 1:
                skipped += delta - 1
            if observed_ordinal > expected_ordinal and observed_ordinal - expected_ordinal > 1:
                order_violations += 1
            ordinal_loop = observed_ordinal // count
            ordinal_frame = observed_ordinal % count
            expected_start = ordinal_loop * total + starts[ordinal_frame]
            if elapsed >= expected_start:
                error = elapsed - expected_start
                if error > tolerance:
                    missed += 1
            else:
                error = expected_start - elapsed
                if error > tolerance:
                    early += 1
            transition_errors.append(error)

        if expected_ordinal > observed_ordinal:
            stale += 1
            mismatch += 1
            max_behind = max(max_behind, expected_ordinal - observed_ordinal)
        elif observed_ordinal > expected_ordinal:
            ahead += 1
            mismatch += 1
            max_ahead = max(max_ahead, observed_ordinal - expected_ordinal)

        previous_elapsed = elapsed
        previous_frame = frame

    return {
        "observationCount": len(observations),
        "transitionCount": transition_count,
        "frameStateMismatchObservationCount": mismatch,
        "staleObservationCount": stale,
        "aheadObservationCount": ahead,
        "frameOrderViolationCount": order_violations,
        "observedSkippedSourceFrameCount": skipped,
        "missedDeadlineCount": missed,
        "earlyDeadlineCount": early,
        "maximumBehindFrameCount": max_behind,
        "maximumAheadFrameCount": max_ahead,
        "p50AbsoluteTimingErrorNanoseconds": percentile(transition_errors, 50),
        "p95AbsoluteTimingErrorNanoseconds": percentile(transition_errors, 95),
        "maximumAbsoluteTimingErrorNanoseconds": max(transition_errors) if transition_errors else None,
        "observedSourceOrdinal": observed_ordinal,
    }


def validate_report(report: dict[str, Any], mode: str) -> list[str]:
    errors: list[str] = []
    expected_control, expected_driver = CONTROL[mode]
    if report.get("schemaVersion") != 1:
        errors.append("unexpected report schema")
    if report.get("evidenceVersion") != "fovea-appkit-physical-callback-timing-v1":
        errors.append("unexpected evidence version")
    if report.get("schedulingControl") != expected_control:
        errors.append("scheduling control mismatch")
    if report.get("driverSchedulingMode") != expected_driver:
        errors.append("driver scheduling mode mismatch")
    checks = report.get("checks")
    if not isinstance(checks, dict) or not checks or not all(checks.values()):
        errors.append("report checks are not all true")
    durations = report.get("frameDurationsNanoseconds")
    observations = report.get("observations")
    if not isinstance(durations, list) or len(durations) < 2 or not all(isinstance(x, int) and x > 0 for x in durations):
        errors.append("invalid frame durations")
        return errors
    if report.get("frameCount") != len(durations):
        errors.append("frame count mismatch")
    if not isinstance(observations, list) or len(observations) < 2:
        errors.append("callback observations missing")
        return errors
    try:
        score = score_report(report, 0)
    except (KeyError, TypeError, ValueError) as error:
        errors.append(f"invalid callback observations: {error}")
        return errors
    if score["observedSourceOrdinal"] < len(durations):
        errors.append("source progression did not reach one full loop")
    if report.get("observedSourceOrdinal") != score["observedSourceOrdinal"]:
        errors.append("stored source progression diverges from raw observations")
    if report.get("registeredDriverCountAfterCancel") != 0:
        errors.append("runtime driver remained registered after cancel")
    return errors


def write_log(path: pathlib.Path, completed: subprocess.CompletedProcess[str]) -> None:
    path.write_text(
        f"returnCode={completed.returncode}\n--- stdout ---\n{completed.stdout}"
        f"\n--- stderr ---\n{completed.stderr}"
    )


def median(values: list[int]) -> int:
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) // 2


def aggregate(results: list[dict[str, Any]], mode: str) -> dict[str, Any]:
    items = [item for item in results if item["mode"] == mode and not item["validationErrors"]]
    scores = [item["score"] for item in items]
    return {
        "validRunCount": len(items),
        "medianP95AbsoluteTimingErrorNanoseconds": median(
            [int(score["p95AbsoluteTimingErrorNanoseconds"]) for score in scores]
        ) if scores else None,
        "totalMissedDeadlineCount": sum(int(score["missedDeadlineCount"]) for score in scores),
        "totalEarlyDeadlineCount": sum(int(score["earlyDeadlineCount"]) for score in scores),
        "totalObservedSkippedSourceFrameCount": sum(
            int(score["observedSkippedSourceFrameCount"]) for score in scores
        ),
        "p95AbsoluteTimingErrorsNanoseconds": [score["p95AbsoluteTimingErrorNanoseconds"] for score in scores],
        "observedSkippedSourceFrameCounts": [score["observedSkippedSourceFrameCount"] for score in scores],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    output = args.output if args.output.is_absolute() else ROOT / args.output
    if output.exists() and any(output.iterdir()):
        print(f"capture output must be new/empty: {output}", file=sys.stderr)
        return 2
    output.mkdir(parents=True, exist_ok=True)

    source_before = git_identity()
    build = run(
        [
            "xcrun", "swift", "build", "-c", "release", "--target", "FoveaAnimationMacLab",
            "-Xswiftc", "-warnings-as-errors",
        ],
        check=False,
    )
    write_log(output / "release-build.log", build)
    if build.returncode != 0:
        print("Release Mac timing lab build failed", file=sys.stderr)
        return build.returncode or 1
    bin_path = pathlib.Path(run(["xcrun", "swift", "build", "-c", "release", "--show-bin-path"]).stdout.strip())
    executable = bin_path / "FoveaAnimationMacLab"
    if not executable.is_file():
        print(f"Mac lab executable missing: {executable}", file=sys.stderr)
        return 1
    executable_identity = file_identity(executable)

    results: list[dict[str, Any]] = []
    runtime_identity: dict[str, Any] | None = None
    all_passed = True
    for pair_index in range(1, FIXED_PAIR_COUNT + 1):
        order = MODES if pair_index % 2 else tuple(reversed(MODES))
        for order_index, mode in enumerate(order, start=1):
            scheduling_control, _ = CONTROL[mode]
            report_path = output / f"pair-{pair_index:02d}-{order_index}-{mode}.json"
            log_path = output / f"pair-{pair_index:02d}-{order_index}-{mode}.log"
            env = os.environ.copy()
            env["NSUnbufferedIO"] = "YES"
            completed = run(
                [
                    str(executable), "--output", str(report_path),
                    "--window-presentation", "nonintrusive",
                    "--experiment", "callback-timing",
                    "--scheduling-control", scheduling_control,
                ],
                env=env,
                check=False,
            )
            write_log(log_path, completed)
            item: dict[str, Any] = {
                "pairIndex": pair_index,
                "orderIndex": order_index,
                "mode": mode,
                "returnCode": completed.returncode,
                "log": file_identity(log_path),
                "validationErrors": [],
            }
            if report_path.is_file():
                item["report"] = file_identity(report_path)
                try:
                    report = json.loads(report_path.read_text())
                except (OSError, json.JSONDecodeError) as error:
                    item["validationErrors"] = [f"report parse failed: {error}"]
                else:
                    errors = validate_report(report, mode)
                    item["validationErrors"] = errors
                    runtime = report.get("runtime")
                    if runtime_identity is None:
                        runtime_identity = runtime
                    elif runtime_identity != runtime:
                        errors.append("runtime identity changed across paired runs")
                    maximum_fps = int((runtime or {}).get("displayMaximumFramesPerSecond", 0))
                    if maximum_fps <= 0:
                        errors.append("invalid display maximum frames per second")
                    else:
                        tolerance = (1_000_000_000 + maximum_fps - 1) // maximum_fps
                        item["deadlineToleranceNanoseconds"] = tolerance
                        try:
                            item["score"] = score_report(report, tolerance)
                        except (KeyError, TypeError, ValueError) as error:
                            errors.append(f"score failed: {error}")
            else:
                item["validationErrors"] = ["report missing"]
            if completed.returncode != 0 or item["validationErrors"]:
                all_passed = False
            results.append(item)

    source_after = git_identity()
    source_unchanged = source_before == source_after
    if not source_unchanged:
        all_passed = False
    aggregates = {mode: aggregate(results, mode) for mode in MODES}
    paired = []
    for pair_index in range(1, FIXED_PAIR_COUNT + 1):
        by_mode = {
            item["mode"]: item for item in results
            if item["pairIndex"] == pair_index and not item["validationErrors"] and "score" in item
        }
        if set(by_mode) != set(MODES):
            paired.append({"pairIndex": pair_index, "valid": False})
            continue
        ext = by_mode["external"]["score"]
        dead = by_mode["deadline"]["score"]
        paired.append({
            "pairIndex": pair_index,
            "valid": True,
            "externalP95NoWorse": ext["p95AbsoluteTimingErrorNanoseconds"] <= dead["p95AbsoluteTimingErrorNanoseconds"],
            "externalSkippedNoWorse": ext["observedSkippedSourceFrameCount"] <= dead["observedSkippedSourceFrameCount"],
            "externalMissedNoWorse": ext["missedDeadlineCount"] <= dead["missedDeadlineCount"],
        })
    valid_pairs = [item for item in paired if item.get("valid")]
    directional = (
        len(valid_pairs) == FIXED_PAIR_COUNT
        and all(
            item["externalP95NoWorse"]
            and item["externalSkippedNoWorse"]
            and item["externalMissedNoWorse"]
            for item in valid_pairs
        )
    )
    manifest = {
        "schemaVersion": 1,
        "studyID": "FOVEA-W5-APPKIT-CALLBACK-TIMING-PHYSICAL-V1",
        "status": "passed-fixed-six-pairs-no-retry" if all_passed else "failed-fixed-six-pairs-preserved",
        "formalClaimEligible": False,
        "claimBoundary": [
            "physical Mac presenter callback timing, not hardware scanout timing",
            "six fixed pairs with alternating order; failures are preserved and never retried",
            "same Fovea source timeline/provider; this is an internal scheduling-control comparison only",
            "one display-refresh period is the preregistered deadline tolerance, matching ComparativeLab W5",
            "no third-party ranking and no energy, thermal, memory, startup, codec, or cross-platform superiority claim",
        ],
        "pairCount": FIXED_PAIR_COUNT,
        "configuration": "Release",
        "sourceBefore": source_before,
        "sourceAfter": source_after,
        "sourceUnchangedDuringCapture": source_unchanged,
        "executable": executable_identity,
        "toolchain": {
            "xcode": run(["xcodebuild", "-version"]).stdout.splitlines(),
            "swift": run(["xcrun", "swift", "--version"]).stdout.splitlines(),
        },
        "runtime": runtime_identity,
        "results": results,
        "aggregates": aggregates,
        "pairedChecks": paired,
        "directionalCallbackTimingNonRegressionAllPairs": directional,
    }
    manifest_path = output / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(manifest_path.relative_to(ROOT))
    return 0 if all_passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
