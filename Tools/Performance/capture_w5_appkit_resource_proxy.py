#!/usr/bin/env python3
"""Capture paired process-resource proxies for AppKit external vs deadline scheduling.

This is deliberately not an energy measurement. It records process rusage from
/usr/bin/time -l around a fixed visible animation workload with no extra display
observer in the deadline control.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = ROOT / ".artifacts/performance/w5-appkit-resource-proxy-physical-v1"
PAIR_COUNT = 6
DURATION_SECONDS = 10
MODES = ("external", "deadline")
CONTROL = {
    "external": ("platform-default", "external-presentation-ticks"),
    "deadline": ("automatic-deadline", "automatic-deadline-loop"),
}
REQUIRED_RUSAGE_FIELDS = {
    "maximum resident set size",
    "voluntary context switches",
    "involuntary context switches",
    "instructions retired",
    "cycles elapsed",
    "peak memory footprint",
}


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
            ["git", "diff", "--binary", "HEAD"], cwd=ROOT, stdout=subprocess.PIPE, check=True
        ).stdout
    )
    untracked = run(["git", "ls-files", "--others", "--exclude-standard", "-z"]).stdout.split("\0")
    for relative in sorted(item for item in untracked if item):
        path = ROOT / relative
        if path.is_file() and not path.is_symlink():
            digest.update(relative.encode() + b"\0" + path.read_bytes() + b"\0")
    return {
        "commit": head,
        "sourceTreeDigest": digest.hexdigest(),
        "includesWorkingTreeChanges": dirty,
    }


def parse_time_l(text: str) -> dict[str, Any]:
    first = re.search(
        r"^\s*([0-9]+(?:\.[0-9]+)?)\s+real\s+([0-9]+(?:\.[0-9]+)?)\s+user\s+([0-9]+(?:\.[0-9]+)?)\s+sys\s*$",
        text,
        re.MULTILINE,
    )
    if first is None:
        raise ValueError("time -l real/user/sys line missing")
    fields: dict[str, int] = {}
    for line in text.splitlines():
        match = re.match(r"^\s*([0-9]+)\s{2,}(.+?)\s*$", line)
        if match:
            fields[match.group(2)] = int(match.group(1))
    missing = sorted(REQUIRED_RUSAGE_FIELDS - fields.keys())
    if missing:
        raise ValueError(f"time -l fields missing: {missing}")
    user = float(first.group(2))
    system = float(first.group(3))
    return {
        "realSeconds": float(first.group(1)),
        "userSeconds": user,
        "systemSeconds": system,
        "totalCPUSeconds": user + system,
        "maximumResidentSetBytes": fields["maximum resident set size"],
        "voluntaryContextSwitches": fields["voluntary context switches"],
        "involuntaryContextSwitches": fields["involuntary context switches"],
        "totalContextSwitches": fields["voluntary context switches"]
        + fields["involuntary context switches"],
        "instructionsRetired": fields["instructions retired"],
        "cyclesElapsed": fields["cycles elapsed"],
        "peakMemoryFootprintBytes": fields["peak memory footprint"],
    }


def validate_report(report: dict[str, Any], mode: str) -> list[str]:
    errors: list[str] = []
    expected_control, expected_driver = CONTROL[mode]
    if report.get("schemaVersion") != 1:
        errors.append("unexpected report schema")
    if report.get("evidenceVersion") != "fovea-appkit-physical-resource-proxy-v1":
        errors.append("unexpected evidence version")
    if report.get("schedulingControl") != expected_control:
        errors.append("scheduling control mismatch")
    if report.get("driverSchedulingMode") != expected_driver:
        errors.append("driver scheduling mode mismatch")
    requested = report.get("requestedDurationNanoseconds")
    measured = report.get("measuredDurationNanoseconds")
    if requested != DURATION_SECONDS * 1_000_000_000:
        errors.append("requested duration mismatch")
    if not isinstance(measured, int) or measured < requested or measured > requested + 1_000_000_000:
        errors.append("measured duration outside bounded wall-time window")
    if not isinstance(report.get("providerFrameCount"), int) or report["providerFrameCount"] <= 0:
        errors.append("provider work missing")
    if report.get("registeredDriverCountAfterCancel") != 0:
        errors.append("runtime driver remained registered after cancel")
    if report.get("providerCancelCountAfterCancel") != 1:
        errors.append("provider cancellation count mismatch")
    checks = report.get("checks")
    if not isinstance(checks, dict) or not checks or not all(checks.values()):
        errors.append("resource proxy checks are not all true")
    if report.get("thermalStateBefore") not in {"nominal", "fair", "serious", "critical", "unknown"}:
        errors.append("invalid initial thermal state")
    if report.get("thermalStateAfter") not in {"nominal", "fair", "serious", "critical", "unknown"}:
        errors.append("invalid final thermal state")
    if mode == "external":
        if not isinstance(report.get("presentationTargetAcceptedCount"), int) or report["presentationTargetAcceptedCount"] <= 0:
            errors.append("external presentation targets missing")
    elif report.get("presentationTargetAcceptedCount") is not None:
        errors.append("deadline control unexpectedly owns presentation-target diagnostics")
    return errors


def median(values: list[float | int]) -> float:
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return float(ordered[middle])
    return (float(ordered[middle - 1]) + float(ordered[middle])) / 2.0


def aggregate(results: list[dict[str, Any]], mode: str) -> dict[str, Any]:
    items = [item for item in results if item["mode"] == mode and not item["validationErrors"]]
    metrics = [item["rusage"] for item in items]
    reports = [item["reportPayload"] for item in items]
    return {
        "validRunCount": len(items),
        "medianTotalCPUSeconds": median([x["totalCPUSeconds"] for x in metrics]) if metrics else None,
        "medianCyclesElapsed": median([x["cyclesElapsed"] for x in metrics]) if metrics else None,
        "medianInstructionsRetired": median([x["instructionsRetired"] for x in metrics]) if metrics else None,
        "medianTotalContextSwitches": median([x["totalContextSwitches"] for x in metrics]) if metrics else None,
        "medianMaximumResidentSetBytes": median([x["maximumResidentSetBytes"] for x in metrics]) if metrics else None,
        "medianPeakMemoryFootprintBytes": median([x["peakMemoryFootprintBytes"] for x in metrics]) if metrics else None,
        "medianProviderFrameCount": median([x["providerFrameCount"] for x in reports]) if reports else None,
        "totalCPUSeconds": [x["totalCPUSeconds"] for x in metrics],
        "cyclesElapsed": [x["cyclesElapsed"] for x in metrics],
        "instructionsRetired": [x["instructionsRetired"] for x in metrics],
        "totalContextSwitches": [x["totalContextSwitches"] for x in metrics],
        "providerFrameCounts": [x["providerFrameCount"] for x in reports],
        "thermalTransitions": [f"{x['thermalStateBefore']}->{x['thermalStateAfter']}" for x in reports],
    }


def ratio(lhs: float, rhs: float) -> float | None:
    return lhs / rhs if rhs > 0 else None


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
    build = run([
        "xcrun", "swift", "build", "-c", "release", "--target", "FoveaAnimationMacLab",
        "-Xswiftc", "-warnings-as-errors",
    ], check=False)
    (output / "release-build.log").write_text(build.stdout + build.stderr)
    if build.returncode != 0:
        print("Release resource proxy build failed", file=sys.stderr)
        return build.returncode or 1
    bin_path = pathlib.Path(run(["xcrun", "swift", "build", "-c", "release", "--show-bin-path"]).stdout.strip())
    executable = bin_path / "FoveaAnimationMacLab"
    if not executable.is_file():
        print("resource proxy executable missing", file=sys.stderr)
        return 1
    executable_identity = file_identity(executable)

    results: list[dict[str, Any]] = []
    runtime_identity: dict[str, Any] | None = None
    all_passed = True
    for pair_index in range(1, PAIR_COUNT + 1):
        order = MODES if pair_index % 2 else tuple(reversed(MODES))
        for order_index, mode in enumerate(order, start=1):
            control, _ = CONTROL[mode]
            report_path = output / f"pair-{pair_index:02d}-{order_index}-{mode}.json"
            time_path = output / f"pair-{pair_index:02d}-{order_index}-{mode}.time.txt"
            stdout_path = output / f"pair-{pair_index:02d}-{order_index}-{mode}.stdout.txt"
            completed = run([
                "/usr/bin/time", "-l", "-o", str(time_path), str(executable),
                "--output", str(report_path), "--window-presentation", "nonintrusive",
                "--experiment", "resource-proxy", "--scheduling-control", control,
                "--duration-seconds", str(DURATION_SECONDS),
            ], check=False)
            stdout_path.write_text(completed.stdout + completed.stderr)
            item: dict[str, Any] = {
                "pairIndex": pair_index,
                "orderIndex": order_index,
                "mode": mode,
                "returnCode": completed.returncode,
                "stdout": file_identity(stdout_path),
                "time": file_identity(time_path) if time_path.is_file() else None,
                "report": file_identity(report_path) if report_path.is_file() else None,
                "validationErrors": [],
            }
            errors = item["validationErrors"]
            if not time_path.is_file():
                errors.append("time -l output missing")
            else:
                try:
                    item["rusage"] = parse_time_l(time_path.read_text())
                except ValueError as error:
                    errors.append(f"rusage parse failed: {error}")
            if not report_path.is_file():
                errors.append("resource proxy report missing")
            else:
                try:
                    report = json.loads(report_path.read_text())
                except (OSError, json.JSONDecodeError) as error:
                    errors.append(f"report parse failed: {error}")
                else:
                    item["reportPayload"] = report
                    errors.extend(validate_report(report, mode))
                    runtime = report.get("runtime")
                    if runtime_identity is None:
                        runtime_identity = runtime
                    elif runtime_identity != runtime:
                        errors.append("runtime identity changed across runs")
            if completed.returncode != 0 or errors:
                all_passed = False
            results.append(item)

    source_after = git_identity()
    source_unchanged = source_before == source_after
    if not source_unchanged:
        all_passed = False
    aggregates = {mode: aggregate(results, mode) for mode in MODES}
    pairs: list[dict[str, Any]] = []
    for pair_index in range(1, PAIR_COUNT + 1):
        by_mode = {
            x["mode"]: x for x in results
            if x["pairIndex"] == pair_index and not x["validationErrors"] and "rusage" in x
        }
        if set(by_mode) != set(MODES):
            pairs.append({"pairIndex": pair_index, "valid": False})
            continue
        ext = by_mode["external"]["rusage"]
        dead = by_mode["deadline"]["rusage"]
        pairs.append({
            "pairIndex": pair_index,
            "valid": True,
            "externalToDeadlineTotalCPURatio": ratio(ext["totalCPUSeconds"], dead["totalCPUSeconds"]),
            "externalToDeadlineCyclesRatio": ratio(ext["cyclesElapsed"], dead["cyclesElapsed"]),
            "externalToDeadlineInstructionsRatio": ratio(ext["instructionsRetired"], dead["instructionsRetired"]),
            "externalToDeadlineContextSwitchRatio": ratio(ext["totalContextSwitches"], dead["totalContextSwitches"]),
            "externalToDeadlineMaximumRSSRatio": ratio(ext["maximumResidentSetBytes"], dead["maximumResidentSetBytes"]),
        })
    valid_pairs = [x for x in pairs if x.get("valid")]
    ratio_keys = [
        "externalToDeadlineTotalCPURatio",
        "externalToDeadlineCyclesRatio",
        "externalToDeadlineInstructionsRatio",
        "externalToDeadlineContextSwitchRatio",
        "externalToDeadlineMaximumRSSRatio",
    ]
    paired_medians = {
        key: median([float(x[key]) for x in valid_pairs]) if valid_pairs else None
        for key in ratio_keys
    }
    manifest = {
        "schemaVersion": 1,
        "studyID": "FOVEA-W5-APPKIT-RESOURCE-PROXY-PHYSICAL-V1",
        "status": "passed-fixed-six-pairs-no-retry" if all_passed else "failed-fixed-six-pairs-preserved",
        "formalEnergyClaimEligible": False,
        "claimBoundary": [
            "process rusage proxy only; never label CPU time/cycles/instructions/context switches as energy",
            "deadline control has no extra display link or timing observer; external mode uses only its normal production display link",
            "six fixed 10-second pairs use alternating order and no retry-until-success path",
            "thermalState is coarse ProcessInfo state and not an energy/temperature endpoint",
            "macOS Xcode Power Profiler is unsupported and powermetrics requires unavailable root authorization on this host",
        ],
        "pairCount": PAIR_COUNT,
        "durationSeconds": DURATION_SECONDS,
        "configuration": "Release",
        "sourceBefore": source_before,
        "sourceAfter": source_after,
        "sourceUnchangedDuringCapture": source_unchanged,
        "executable": executable_identity,
        "runtime": runtime_identity,
        "results": results,
        "aggregates": aggregates,
        "pairedRatios": pairs,
        "medianPairedRatios": paired_medians,
        "toolchain": {
            "xcode": run(["xcodebuild", "-version"]).stdout.splitlines(),
            "swift": run(["xcrun", "swift", "--version"]).stdout.splitlines(),
        },
    }
    # Remove bulky duplicate report payloads from persisted per-run items after aggregation.
    for item in manifest["results"]:
        item.pop("reportPayload", None)
    path = output / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(path.relative_to(ROOT))
    return 0 if all_passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
