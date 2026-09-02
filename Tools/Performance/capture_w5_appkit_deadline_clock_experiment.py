#!/usr/bin/env python3
"""Capture fixed-block physical-Mac AppKit scheduler/clock timing and resource evidence."""

from __future__ import annotations

import argparse
import importlib.util
import json
import pathlib
import statistics
import sys
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = ROOT / ".artifacts/performance/w5-appkit-deadline-clock-physical-v1"
BLOCK_COUNT = 6
RESOURCE_DURATION_SECONDS = 10
MODE_ORDER = ("external", "taskDeadline", "strictDeadline")
MODE_CONFIG = {
    "external": ("platform-default", "system-task-sleep", "external"),
    "taskDeadline": ("automatic-deadline", "system-task-sleep", "deadline"),
    "strictDeadline": ("automatic-deadline", "strict-dispatch", "deadline"),
}


def load_module(name: str, relative: str):
    path = ROOT / relative
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


REFRESH = load_module(
    "fovea_w5_refresh_capture",
    "Tools/Performance/capture_w5_appkit_refresh_timing.py",
)
RESOURCE = load_module(
    "fovea_w5_resource_capture",
    "Tools/Performance/capture_w5_appkit_resource_proxy.py",
)


def block_order(block_index: int, phase: str) -> tuple[str, ...]:
    if not 1 <= block_index <= BLOCK_COUNT or phase not in {"timing", "resource"}:
        raise ValueError("invalid block order request")
    offset = (block_index - 1 + (1 if phase == "resource" else 0)) % len(MODE_ORDER)
    return MODE_ORDER[offset:] + MODE_ORDER[:offset]


def mode_arguments(mode: str) -> list[str]:
    scheduling, clock, _ = MODE_CONFIG[mode]
    result = ["--scheduling-control", scheduling]
    if clock != "system-task-sleep":
        result += ["--deadline-clock", clock]
    return result


def expected_clock(mode: str) -> str:
    return MODE_CONFIG[mode][1]


def median(values: list[float | int]) -> float | None:
    return float(statistics.median(values)) if values else None


def ratio(lhs: float | int, rhs: float | int) -> float | None:
    return float(lhs) / float(rhs) if rhs else None


def validate_clock_binding(report: dict[str, Any], mode: str) -> list[str]:
    return (
        []
        if report.get("deadlineClockControl") == expected_clock(mode)
        else ["deadline clock control mismatch"]
    )


def timing_aggregate(items: list[dict[str, Any]], mode: str) -> dict[str, Any]:
    selected = [
        item for item in items
        if item["mode"] == mode and not item["validationErrors"] and "anchoredScore" in item
    ]
    scores = [item["anchoredScore"] for item in selected]
    refresh_medians = [item["observedMedianRefreshIntervalNanoseconds"] for item in selected]
    return {
        "validRunCount": len(selected),
        "medianAnchoredP95AbsoluteTimingErrorNanoseconds": median(
            [int(score["p95AbsoluteTimingErrorNanoseconds"]) for score in scores]
        ),
        "totalObservedSkippedSourceFrameCount": sum(
            int(score["observedSkippedSourceFrameCount"]) for score in scores
        ),
        "totalAnchoredMissedDeadlineCount": sum(
            int(score["missedDeadlineCount"]) for score in scores
        ),
        "anchoredP95AbsoluteTimingErrorsNanoseconds": [
            score["p95AbsoluteTimingErrorNanoseconds"] for score in scores
        ],
        "observedSkippedSourceFrameCounts": [
            score["observedSkippedSourceFrameCount"] for score in scores
        ],
        "observedMedianRefreshIntervalsNanoseconds": refresh_medians,
    }


def resource_aggregate(items: list[dict[str, Any]], mode: str) -> dict[str, Any]:
    selected = [
        item for item in items
        if item["mode"] == mode and not item["validationErrors"] and "rusage" in item
    ]
    metrics = [item["rusage"] for item in selected]
    reports = [item["reportPayload"] for item in selected]
    return {
        "validRunCount": len(selected),
        "medianTotalCPUSeconds": median([metric["totalCPUSeconds"] for metric in metrics]),
        "medianCyclesElapsed": median([metric["cyclesElapsed"] for metric in metrics]),
        "medianInstructionsRetired": median([metric["instructionsRetired"] for metric in metrics]),
        "medianTotalContextSwitches": median(
            [metric["totalContextSwitches"] for metric in metrics]
        ),
        "medianMaximumResidentSetBytes": median(
            [metric["maximumResidentSetBytes"] for metric in metrics]
        ),
        "medianProviderFrameCount": median(
            [report["providerFrameCount"] for report in reports]
        ),
        "totalCPUSeconds": [metric["totalCPUSeconds"] for metric in metrics],
        "cyclesElapsed": [metric["cyclesElapsed"] for metric in metrics],
        "instructionsRetired": [metric["instructionsRetired"] for metric in metrics],
        "totalContextSwitches": [metric["totalContextSwitches"] for metric in metrics],
        "maximumResidentSetBytes": [metric["maximumResidentSetBytes"] for metric in metrics],
        "thermalTransitions": [
            f"{report['thermalStateBefore']}->{report['thermalStateAfter']}"
            for report in reports
        ],
    }


def block_checks(
    timing_items: list[dict[str, Any]], resource_items: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    checks: list[dict[str, Any]] = []
    for block_index in range(1, BLOCK_COUNT + 1):
        timing = {
            item["mode"]: item
            for item in timing_items
            if item["blockIndex"] == block_index
            and not item["validationErrors"]
            and "anchoredScore" in item
        }
        resources = {
            item["mode"]: item
            for item in resource_items
            if item["blockIndex"] == block_index
            and not item["validationErrors"]
            and "rusage" in item
        }
        if set(timing) != set(MODE_ORDER) or set(resources) != set(MODE_ORDER):
            checks.append({"blockIndex": block_index, "valid": False})
            continue
        strict_t = timing["strictDeadline"]["anchoredScore"]
        task_t = timing["taskDeadline"]["anchoredScore"]
        external_t = timing["external"]["anchoredScore"]
        strict_r = resources["strictDeadline"]["rusage"]
        task_r = resources["taskDeadline"]["rusage"]
        external_r = resources["external"]["rusage"]
        checks.append(
            {
                "blockIndex": block_index,
                "valid": True,
                "strictVsTaskAnchoredP95NoWorse": (
                    strict_t["p95AbsoluteTimingErrorNanoseconds"]
                    <= task_t["p95AbsoluteTimingErrorNanoseconds"]
                ),
                "strictVsTaskSkippedNoWorse": (
                    strict_t["observedSkippedSourceFrameCount"]
                    <= task_t["observedSkippedSourceFrameCount"]
                ),
                "strictVsTaskCPUNoWorse": (
                    strict_r["totalCPUSeconds"] <= task_r["totalCPUSeconds"]
                ),
                "strictVsTaskCyclesNoWorse": (
                    strict_r["cyclesElapsed"] <= task_r["cyclesElapsed"]
                ),
                "strictVsTaskInstructionsNoWorse": (
                    strict_r["instructionsRetired"] <= task_r["instructionsRetired"]
                ),
                "strictVsTaskContextSwitchesNoWorse": (
                    strict_r["totalContextSwitches"] <= task_r["totalContextSwitches"]
                ),
                "strictVsExternalAnchoredP95Ratio": ratio(
                    strict_t["p95AbsoluteTimingErrorNanoseconds"],
                    external_t["p95AbsoluteTimingErrorNanoseconds"],
                ),
                "strictVsExternalSkippedDelta": (
                    strict_t["observedSkippedSourceFrameCount"]
                    - external_t["observedSkippedSourceFrameCount"]
                ),
                "strictVsExternalCPURatio": ratio(
                    strict_r["totalCPUSeconds"], external_r["totalCPUSeconds"]
                ),
                "strictVsExternalCyclesRatio": ratio(
                    strict_r["cyclesElapsed"], external_r["cyclesElapsed"]
                ),
                "strictVsExternalInstructionsRatio": ratio(
                    strict_r["instructionsRetired"], external_r["instructionsRetired"]
                ),
                "strictVsExternalContextSwitchRatio": ratio(
                    strict_r["totalContextSwitches"],
                    external_r["totalContextSwitches"],
                ),
            }
        )
    return checks


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    output = args.output if args.output.is_absolute() else ROOT / args.output
    if output.exists() and any(output.iterdir()):
        print(f"capture output must be new/empty: {output}", file=sys.stderr)
        return 2
    output.mkdir(parents=True, exist_ok=True)

    source_before = REFRESH.git_identity()
    build = REFRESH.run(
        [
            "xcrun", "swift", "build", "-c", "release", "--target",
            "FoveaAnimationMacLab", "-Xswiftc", "-warnings-as-errors",
        ],
        check=False,
    )
    REFRESH.write_log(output / "release-build.log", build)
    if build.returncode != 0:
        print("Release deadline-clock experiment build failed", file=sys.stderr)
        return build.returncode or 1
    bin_path = pathlib.Path(
        REFRESH.run(
            ["xcrun", "swift", "build", "-c", "release", "--show-bin-path"]
        ).stdout.strip()
    )
    executable = bin_path / "FoveaAnimationMacLab"
    if not executable.is_file():
        print(f"Mac lab executable missing: {executable}", file=sys.stderr)
        return 1
    executable_identity = REFRESH.file_identity(executable)

    timing_results: list[dict[str, Any]] = []
    resource_results: list[dict[str, Any]] = []
    runtime_identity: dict[str, Any] | None = None
    all_capture_valid = True

    for block_index in range(1, BLOCK_COUNT + 1):
        for order_index, mode in enumerate(block_order(block_index, "timing"), start=1):
            report_path = output / f"timing-b{block_index:02d}-{order_index}-{mode}.json"
            log_path = output / f"timing-b{block_index:02d}-{order_index}-{mode}.log"
            command = [
                str(executable), "--output", str(report_path),
                "--window-presentation", "nonintrusive", "--experiment", "refresh-timing",
                *mode_arguments(mode),
            ]
            completed = REFRESH.run(command, check=False)
            REFRESH.write_log(log_path, completed)
            item: dict[str, Any] = {
                "blockIndex": block_index,
                "orderIndex": order_index,
                "mode": mode,
                "returnCode": completed.returncode,
                "log": REFRESH.file_identity(log_path),
                "validationErrors": [],
            }
            if report_path.is_file():
                item["report"] = REFRESH.file_identity(report_path)
                try:
                    report = json.loads(report_path.read_text())
                except (OSError, json.JSONDecodeError) as error:
                    item["validationErrors"] = [f"report parse failed: {error}"]
                else:
                    _, _, validator_mode = MODE_CONFIG[mode]
                    errors = REFRESH.validate_report(report, validator_mode)
                    errors += validate_clock_binding(report, mode)
                    item["validationErrors"] = errors
                    runtime = report.get("runtime")
                    if runtime_identity is None:
                        runtime_identity = runtime
                    elif runtime_identity != runtime:
                        errors.append("runtime identity changed across experiment")
                    maximum_fps = int((runtime or {}).get("displayMaximumFramesPerSecond", 0))
                    if maximum_fps <= 0:
                        errors.append("invalid display maximum frames per second")
                    else:
                        tolerance = (1_000_000_000 + maximum_fps - 1) // maximum_fps
                        item["deadlineToleranceNanoseconds"] = tolerance
                        item["normalizedScore"] = REFRESH.score_report(report, tolerance)
                        item["anchoredScore"] = REFRESH.score_report_anchored(report, tolerance)
                        intervals = report.get("refreshIntervalsNanoseconds") or []
                        if intervals:
                            item["observedMedianRefreshIntervalNanoseconds"] = int(
                                statistics.median(int(value) for value in intervals)
                            )
                        else:
                            errors.append("refresh intervals missing")
            else:
                item["validationErrors"] = ["report missing"]
            if completed.returncode != 0 or item["validationErrors"]:
                all_capture_valid = False
            timing_results.append(item)

        for order_index, mode in enumerate(block_order(block_index, "resource"), start=1):
            report_path = output / f"resource-b{block_index:02d}-{order_index}-{mode}.json"
            log_path = output / f"resource-b{block_index:02d}-{order_index}-{mode}.log"
            time_path = output / f"resource-b{block_index:02d}-{order_index}-{mode}.time.txt"
            command = [
                "/usr/bin/time", "-l", "-o", str(time_path), str(executable),
                "--output", str(report_path), "--window-presentation", "nonintrusive",
                "--experiment", "resource-proxy", *mode_arguments(mode),
                "--duration-seconds", str(RESOURCE_DURATION_SECONDS),
            ]
            completed = REFRESH.run(command, check=False)
            REFRESH.write_log(log_path, completed)
            item = {
                "blockIndex": block_index,
                "orderIndex": order_index,
                "mode": mode,
                "returnCode": completed.returncode,
                "log": REFRESH.file_identity(log_path),
                "validationErrors": [],
            }
            if report_path.is_file() and time_path.is_file():
                item["report"] = REFRESH.file_identity(report_path)
                item["timeOutput"] = REFRESH.file_identity(time_path)
                try:
                    report = json.loads(report_path.read_text())
                    rusage = RESOURCE.parse_time_l(time_path.read_text())
                except (OSError, json.JSONDecodeError, ValueError, KeyError) as error:
                    item["validationErrors"] = [f"resource parse failed: {error}"]
                else:
                    _, _, validator_mode = MODE_CONFIG[mode]
                    errors = RESOURCE.validate_report(report, validator_mode)
                    errors += validate_clock_binding(report, mode)
                    item["validationErrors"] = errors
                    runtime = report.get("runtime")
                    if runtime_identity is None:
                        runtime_identity = runtime
                    elif runtime_identity != runtime:
                        errors.append("runtime identity changed across experiment")
                    item["rusage"] = rusage
                    item["reportPayload"] = report
            else:
                item["validationErrors"] = ["resource report/time output missing"]
            if completed.returncode != 0 or item["validationErrors"]:
                all_capture_valid = False
            resource_results.append(item)

    source_after = REFRESH.git_identity()
    source_unchanged = source_before == source_after
    if not source_unchanged:
        all_capture_valid = False

    timing_aggregates = {mode: timing_aggregate(timing_results, mode) for mode in MODE_ORDER}
    resource_aggregates = {
        mode: resource_aggregate(resource_results, mode) for mode in MODE_ORDER
    }
    checks = block_checks(timing_results, resource_results)
    valid_checks = [item for item in checks if item.get("valid")]
    strict_vs_task_local_pareto_all_blocks = (
        len(valid_checks) == BLOCK_COUNT
        and all(
            item["strictVsTaskAnchoredP95NoWorse"]
            and item["strictVsTaskSkippedNoWorse"]
            and item["strictVsTaskCPUNoWorse"]
            and item["strictVsTaskCyclesNoWorse"]
            and item["strictVsTaskInstructionsNoWorse"]
            and item["strictVsTaskContextSwitchesNoWorse"]
            for item in valid_checks
        )
    )

    strict_t = timing_aggregates["strictDeadline"]
    task_t = timing_aggregates["taskDeadline"]
    external_t = timing_aggregates["external"]
    strict_r = resource_aggregates["strictDeadline"]
    task_r = resource_aggregates["taskDeadline"]
    external_r = resource_aggregates["external"]
    aggregate_ratios = {
        "strictToTaskAnchoredP95Ratio": ratio(
            strict_t["medianAnchoredP95AbsoluteTimingErrorNanoseconds"],
            task_t["medianAnchoredP95AbsoluteTimingErrorNanoseconds"],
        ),
        "strictToExternalAnchoredP95Ratio": ratio(
            strict_t["medianAnchoredP95AbsoluteTimingErrorNanoseconds"],
            external_t["medianAnchoredP95AbsoluteTimingErrorNanoseconds"],
        ),
        "strictToTaskCPURatio": ratio(
            strict_r["medianTotalCPUSeconds"], task_r["medianTotalCPUSeconds"]
        ),
        "strictToExternalCPURatio": ratio(
            strict_r["medianTotalCPUSeconds"], external_r["medianTotalCPUSeconds"]
        ),
        "strictToTaskCyclesRatio": ratio(
            strict_r["medianCyclesElapsed"], task_r["medianCyclesElapsed"]
        ),
        "strictToExternalCyclesRatio": ratio(
            strict_r["medianCyclesElapsed"], external_r["medianCyclesElapsed"]
        ),
        "strictToTaskContextSwitchRatio": ratio(
            strict_r["medianTotalContextSwitches"],
            task_r["medianTotalContextSwitches"],
        ),
        "strictToExternalContextSwitchRatio": ratio(
            strict_r["medianTotalContextSwitches"],
            external_r["medianTotalContextSwitches"],
        ),
        "strictToTaskMaximumRSSRatio": ratio(
            strict_r["medianMaximumResidentSetBytes"],
            task_r["medianMaximumResidentSetBytes"],
        ),
        "strictToExternalMaximumRSSRatio": ratio(
            strict_r["medianMaximumResidentSetBytes"],
            external_r["medianMaximumResidentSetBytes"],
        ),
    }

    manifest = {
        "schemaVersion": 1,
        "studyID": "FOVEA-W5-APPKIT-DEADLINE-CLOCK-PHYSICAL-V1",
        "status": (
            "passed-fixed-six-blocks-no-retry"
            if all_capture_valid
            else "failed-fixed-six-blocks-preserved"
        ),
        "formalClaimEligible": False,
        "claimBoundary": [
            "physical Mac internal Fovea scheduling experiment only",
            "strict-dispatch clock is benchmark-only and is not a production behavior change",
            "timing uses common view-display-link refresh sampling and start-anchored scoring",
            "resource proxy uses /usr/bin/time -l with no extra display observer in deadline modes",
            "resource metrics are not energy measurements; the macOS energy endpoint remains blocked",
            "six fixed blocks with preregistered rotated order; failures are preserved and never retried",
            "no third-party, cross-platform, codec, startup, or global Pareto claim",
        ],
        "blockCount": BLOCK_COUNT,
        "resourceDurationSeconds": RESOURCE_DURATION_SECONDS,
        "configuration": "Release",
        "modes": {
            mode: {
                "schedulingControl": MODE_CONFIG[mode][0],
                "deadlineClockControl": MODE_CONFIG[mode][1],
            }
            for mode in MODE_ORDER
        },
        "sourceBefore": source_before,
        "sourceAfter": source_after,
        "sourceUnchangedDuringCapture": source_unchanged,
        "executable": executable_identity,
        "toolchain": {
            "xcode": REFRESH.run(["xcodebuild", "-version"]).stdout.splitlines(),
            "swift": REFRESH.run(["xcrun", "swift", "--version"]).stdout.splitlines(),
        },
        "runtime": runtime_identity,
        "timingResults": timing_results,
        "resourceResults": resource_results,
        "timingAggregates": timing_aggregates,
        "resourceAggregates": resource_aggregates,
        "blockChecks": checks,
        "strictVsTaskLocalParetoAllBlocks": strict_vs_task_local_pareto_all_blocks,
        "aggregateRatios": aggregate_ratios,
    }
    manifest_path = output / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(manifest_path.relative_to(ROOT))
    return 0 if all_capture_valid else 1


if __name__ == "__main__":
    raise SystemExit(main())
