#!/usr/bin/env python3
"""Confirm the AppKit buffered source-boundary fast path against same-binary every-refresh control."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import pathlib
import subprocess
import sys
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[2]
PLAN = ROOT / "docs/research/w5-appkit-buffered-boundary-confirmation-plan-2026-08.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/performance/w5-appkit-buffered-boundary-confirmation-v1"


def load_module(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


refresh = load_module("w5_refresh", ROOT / "Tools/Performance/capture_w5_appkit_refresh_timing.py")
resource = load_module("w5_resource", ROOT / "Tools/Performance/capture_w5_appkit_resource_proxy.py")


def run(command: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and completed.returncode != 0:
        raise RuntimeError(
            f"command failed ({completed.returncode}): {' '.join(command)}\n"
            + completed.stdout + completed.stderr
        )
    return completed


def file_identity(path: pathlib.Path) -> dict[str, object]:
    data = path.read_bytes()
    return {
        "path": str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path),
        "byteCount": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def median(values: list[float | int]) -> float:
    ordered = sorted(float(value) for value in values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2.0


def validate_timing_report(report: dict[str, Any], control: str) -> list[str]:
    errors: list[str] = []
    if report.get("schemaVersion") != 1:
        errors.append("unexpected timing schema")
    if report.get("evidenceVersion") != "fovea-appkit-physical-refresh-sampled-timing-v1":
        errors.append("unexpected timing evidence version")
    if report.get("schedulingControl") != control:
        errors.append("timing scheduling control mismatch")
    if report.get("driverSchedulingMode") != "external-presentation-ticks":
        errors.append("timing driver mode mismatch")
    checks = report.get("checks")
    if not isinstance(checks, dict) or not checks or not all(checks.values()):
        errors.append("timing checks are not all true")
    if report.get("registeredDriverCountAfterCancel") != 0:
        errors.append("timing driver remained registered after cancel")
    try:
        score = refresh.score_report_anchored(report, 0)
    except (KeyError, TypeError, ValueError) as error:
        errors.append(f"timing score failed: {error}")
    else:
        if score["observedAbsoluteSourceOrdinal"] < int(report.get("frameCount", 0)):
            errors.append("timing source progression incomplete")
    return errors


def validate_resource_report(report: dict[str, Any], control: str, duration_seconds: int) -> list[str]:
    errors: list[str] = []
    if report.get("schemaVersion") != 1:
        errors.append("unexpected resource schema")
    if report.get("evidenceVersion") != "fovea-appkit-physical-resource-proxy-v1":
        errors.append("unexpected resource evidence version")
    if report.get("schedulingControl") != control:
        errors.append("resource scheduling control mismatch")
    if report.get("driverSchedulingMode") != "external-presentation-ticks":
        errors.append("resource driver mode mismatch")
    requested = duration_seconds * 1_000_000_000
    measured = report.get("measuredDurationNanoseconds")
    if report.get("requestedDurationNanoseconds") != requested:
        errors.append("resource requested duration mismatch")
    if not isinstance(measured, int) or measured < requested or measured > requested + 1_000_000_000:
        errors.append("resource measured duration outside bounded window")
    if report.get("registeredDriverCountAfterCancel") != 0:
        errors.append("resource driver remained registered after cancel")
    if report.get("providerCancelCountAfterCancel") != 1:
        errors.append("resource provider cancellation mismatch")
    checks = report.get("checks")
    if not isinstance(checks, dict) or not checks or not all(checks.values()):
        errors.append("resource checks are not all true")
    return errors


def metric_ratio(candidate: dict[str, Any], baseline: dict[str, Any], key: str) -> float:
    denominator = float(baseline[key])
    if denominator <= 0:
        raise ValueError(f"nonpositive baseline metric: {key}")
    return float(candidate[key]) / denominator


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    output = args.output if args.output.is_absolute() else ROOT / args.output
    if output.exists() and any(output.iterdir()):
        print(f"capture output must be new/empty: {output}", file=sys.stderr)
        return 2
    output.mkdir(parents=True, exist_ok=True)

    plan = json.loads(PLAN.read_text())
    pair_count = int(plan["pairCount"])
    duration_seconds = int(plan["resourceDurationSeconds"])
    controls = dict(plan["controls"])
    pair_order = plan["pairOrder"]
    if len(pair_order) != pair_count:
        raise RuntimeError("plan pair order count mismatch")

    source_before = resource.git_identity()
    build = run([
        "xcrun", "swift", "build", "-c", "release", "--target", "FoveaAnimationMacLab",
        "-Xswiftc", "-warnings-as-errors",
    ], check=False)
    (output / "release-build.log").write_text(build.stdout + build.stderr)
    if build.returncode != 0:
        print("confirmation Release build failed", file=sys.stderr)
        return build.returncode or 1
    bin_path = pathlib.Path(run(["xcrun", "swift", "build", "-c", "release", "--show-bin-path"]).stdout.strip())
    executable = bin_path / "FoveaAnimationMacLab"
    if not executable.is_file():
        print("confirmation executable missing", file=sys.stderr)
        return 1
    executable_identity = file_identity(executable)

    results: list[dict[str, Any]] = []
    runtime_identity: dict[str, Any] | None = None
    capture_valid = True
    for pair_index, order in enumerate(pair_order, start=1):
        print(f"pair {pair_index}/{pair_count}: {' -> '.join(order)}", flush=True)
        for order_index, mode in enumerate(order, start=1):
            control = controls[mode]
            prefix = f"pair-{pair_index:02d}-{order_index}-{mode}"
            timing_path = output / f"{prefix}-timing.json"
            timing_log = output / f"{prefix}-timing.log"
            timing_run = run([
                str(executable), "--output", str(timing_path),
                "--window-presentation", "nonintrusive", "--experiment", "refresh-timing",
                "--scheduling-control", control,
            ], check=False)
            timing_log.write_text(timing_run.stdout + timing_run.stderr)

            resource_path = output / f"{prefix}-resource.json"
            time_path = output / f"{prefix}.time.txt"
            resource_log = output / f"{prefix}-resource.log"
            resource_run = run([
                "/usr/bin/time", "-l", "-o", str(time_path), str(executable),
                "--output", str(resource_path), "--window-presentation", "nonintrusive",
                "--experiment", "resource-proxy", "--scheduling-control", control,
                "--duration-seconds", str(duration_seconds),
            ], check=False)
            resource_log.write_text(resource_run.stdout + resource_run.stderr)

            item: dict[str, Any] = {
                "pairIndex": pair_index,
                "orderIndex": order_index,
                "mode": mode,
                "control": control,
                "timingReturnCode": timing_run.returncode,
                "resourceReturnCode": resource_run.returncode,
                "validationErrors": [],
            }
            errors: list[str] = item["validationErrors"]
            if timing_path.is_file():
                timing_report = json.loads(timing_path.read_text())
                errors.extend(validate_timing_report(timing_report, control))
                if not errors:
                    item["timingScore"] = refresh.score_report_anchored(timing_report, 0)
                    item["timingMedianRefreshNanoseconds"] = median(
                        [int(x) for x in timing_report["refreshIntervalsNanoseconds"]]
                    )
                item["timingAcceptedTargetCount"] = timing_report.get("presentationTargetAcceptedCount")
                item["timingConsumedTargetCount"] = timing_report.get("presentationTargetConsumedCount")
                item["timingRefreshSampleCount"] = timing_report.get("refreshSampleCount")
                runtime = timing_report.get("runtime")
                if runtime_identity is None:
                    runtime_identity = runtime
                elif runtime_identity != runtime:
                    errors.append("runtime identity changed")
            else:
                errors.append("timing report missing")
            if resource_path.is_file():
                resource_report = json.loads(resource_path.read_text())
                errors.extend(validate_resource_report(resource_report, control, duration_seconds))
                item["thermalBefore"] = resource_report.get("thermalStateBefore")
                item["thermalAfter"] = resource_report.get("thermalStateAfter")
            else:
                errors.append("resource report missing")
            if time_path.is_file():
                try:
                    item["rusage"] = resource.parse_time_l(time_path.read_text())
                except ValueError as error:
                    errors.append(f"time -l parse failed: {error}")
            else:
                errors.append("time -l output missing")
            if timing_run.returncode != 0 or resource_run.returncode != 0 or errors:
                capture_valid = False
            item["timing"] = file_identity(timing_path) if timing_path.is_file() else None
            item["resource"] = file_identity(resource_path) if resource_path.is_file() else None
            item["time"] = file_identity(time_path) if time_path.is_file() else None
            item["timingLog"] = file_identity(timing_log)
            item["resourceLog"] = file_identity(resource_log)
            results.append(item)

    source_after = resource.git_identity()
    source_unchanged = source_before == source_after
    if not source_unchanged:
        capture_valid = False

    pairs: list[dict[str, Any]] = []
    resource_keys = {
        "totalCPUSeconds": "totalCPUSeconds",
        "cyclesElapsed": "cyclesElapsed",
        "instructionsRetired": "instructionsRetired",
        "totalContextSwitches": "totalContextSwitches",
        "maximumResidentSetBytes": "maximumResidentSetBytes",
    }
    for pair_index in range(1, pair_count + 1):
        by_mode = {
            item["mode"]: item for item in results
            if item["pairIndex"] == pair_index and not item["validationErrors"]
        }
        pair: dict[str, Any] = {"pairIndex": pair_index, "valid": set(by_mode) == {"baseline", "candidate"}}
        if not pair["valid"]:
            pairs.append(pair)
            continue
        baseline = by_mode["baseline"]
        candidate = by_mode["candidate"]
        bscore = baseline["timingScore"]
        cscore = candidate["timingScore"]
        margin = max(
            float(baseline["timingMedianRefreshNanoseconds"]),
            float(candidate["timingMedianRefreshNanoseconds"]),
        )
        pair["baselineP95Nanoseconds"] = bscore["p95AbsoluteTimingErrorNanoseconds"]
        pair["candidateP95Nanoseconds"] = cscore["p95AbsoluteTimingErrorNanoseconds"]
        pair["refreshMarginNanoseconds"] = margin
        pair["p95WithinOneRefreshMargin"] = (
            float(cscore["p95AbsoluteTimingErrorNanoseconds"])
            <= float(bscore["p95AbsoluteTimingErrorNanoseconds"]) + margin
        )
        pair["baselineSourceSkips"] = bscore["observedSkippedSourceFrameCount"]
        pair["candidateSourceSkips"] = cscore["observedSkippedSourceFrameCount"]
        pair["noAdditionalSourceSkips"] = (
            int(cscore["observedSkippedSourceFrameCount"])
            <= int(bscore["observedSkippedSourceFrameCount"])
        )
        pair["candidateAcceptedEqualsRefreshSamples"] = (
            candidate["timingAcceptedTargetCount"] == candidate["timingRefreshSampleCount"]
        )
        baseline_consumed = int(baseline["timingConsumedTargetCount"] or 0)
        candidate_consumed = int(candidate["timingConsumedTargetCount"] or 0)
        pair["candidateConsumedToBaselineConsumedRatio"] = (
            candidate_consumed / baseline_consumed if baseline_consumed > 0 else None
        )
        pair["resourceRatios"] = {
            name: metric_ratio(candidate["rusage"], baseline["rusage"], key)
            for name, key in resource_keys.items()
        }
        pairs.append(pair)

    timing_gate = plan["timingGate"]
    resource_gate = plan["resourceGate"]
    valid_pairs = [pair for pair in pairs if pair.get("valid")]
    all_pair_count = len(valid_pairs) == pair_count
    timing_checks = {
        "fixedPairCountValid": all_pair_count,
        "allPairsNoAdditionalSourceSkips": all_pair_count and all(pair["noAdditionalSourceSkips"] for pair in valid_pairs),
        "allPairsP95WithinBaselinePlusOneObservedRefresh": all_pair_count and all(pair["p95WithinOneRefreshMargin"] for pair in valid_pairs),
        "candidateAcceptedTargetCountEqualsRefreshSampleCount": all_pair_count and all(pair["candidateAcceptedEqualsRefreshSamples"] for pair in valid_pairs),
        "candidateConsumedRatioEveryPair": all_pair_count and all(
            pair["candidateConsumedToBaselineConsumedRatio"] is not None
            and pair["candidateConsumedToBaselineConsumedRatio"] <= float(timing_gate["candidateConsumedToBaselineConsumedMaximumRatioEveryPair"])
            for pair in valid_pairs
        ),
    }
    median_ratios = {
        name: median([pair["resourceRatios"][name] for pair in valid_pairs]) if valid_pairs else None
        for name in resource_keys
    }
    median_limits = resource_gate["medianPairedMaximumRatios"]
    catastrophic_limits = resource_gate["everyPairCatastrophicMaximumRatios"]
    resource_checks = {
        "medianResourceRatios": all_pair_count and all(
            median_ratios[name] is not None and median_ratios[name] <= float(median_limits[name])
            for name in resource_keys
        ),
        "noCatastrophicPairRegression": all_pair_count and all(
            pair["resourceRatios"][name] <= float(catastrophic_limits[name])
            for pair in valid_pairs for name in resource_keys
        ),
        "thermalStatesNominalOrFair": all(
            item.get("thermalBefore") in {"nominal", "fair"}
            and item.get("thermalAfter") in {"nominal", "fair"}
            for item in results if not item["validationErrors"]
        ),
    }
    adoption_gate_passed = (
        capture_valid and source_unchanged
        and all(timing_checks.values())
        and all(resource_checks.values())
    )

    manifest = {
        "schemaVersion": 1,
        "studyID": plan["studyID"],
        "status": "confirmation-passed" if adoption_gate_passed else "confirmation-failed-preserved",
        "adoptionGatePassed": adoption_gate_passed,
        "formalEnergyClaimEligible": False,
        "plan": file_identity(PLAN),
        "configuration": "Release",
        "pairCount": pair_count,
        "resourceDurationSeconds": duration_seconds,
        "sourceBefore": source_before,
        "sourceAfter": source_after,
        "sourceUnchangedDuringCapture": source_unchanged,
        "executable": executable_identity,
        "runtime": runtime_identity,
        "results": results,
        "pairs": pairs,
        "timingChecks": timing_checks,
        "medianPairedResourceRatios": median_ratios,
        "resourceChecks": resource_checks,
        "claimBoundary": plan["claimBoundary"],
        "toolchain": {
            "xcode": run(["xcodebuild", "-version"]).stdout.splitlines(),
            "swift": run(["xcrun", "swift", "--version"]).stdout.splitlines(),
        },
    }
    for item in manifest["results"]:
        item.pop("rusage", None)
        item.pop("timingScore", None)
    manifest_path = output / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(manifest_path.relative_to(ROOT), flush=True)
    print(json.dumps({
        "adoptionGatePassed": adoption_gate_passed,
        "timingChecks": timing_checks,
        "medianPairedResourceRatios": median_ratios,
        "resourceChecks": resource_checks,
    }, indent=2, sort_keys=True), flush=True)
    return 0 if adoption_gate_passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
