#!/usr/bin/env python3
"""Capture fixed-count physical-Mac AppKit display-link mechanism evidence."""

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
DEFAULT_OUTPUT = ROOT / ".artifacts/performance/w5-appkit-display-link-physical-v1"
FIXED_RUN_COUNT = 6


def run(
    command: list[str],
    *,
    env: dict[str, str] | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
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


def validate_report(report: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if report.get("schemaVersion") != 1:
        errors.append("unexpected report schema")
    if report.get("evidenceVersion") != "fovea-appkit-physical-display-link-mechanism-v1":
        errors.append("unexpected evidence version")
    checks = report.get("checks")
    if not isinstance(checks, dict) or not checks or not all(checks.values()):
        errors.append("report checks are not all true")

    stages: dict[str, dict[str, Any]] = {}
    for name in ("active", "hiddenSettled", "hiddenEnd", "resumed"):
        value = report.get(name)
        if not isinstance(value, dict) or not isinstance(value.get("presentation"), dict):
            errors.append(f"missing stage: {name}")
            continue
        stages[name] = value
    if len(stages) != 4:
        return errors

    active = stages["active"]
    hidden_settled = stages["hiddenSettled"]
    hidden_end = stages["hiddenEnd"]
    resumed = stages["resumed"]
    active_p = active["presentation"]
    hidden_settled_p = hidden_settled["presentation"]
    hidden_end_p = hidden_end["presentation"]
    resumed_p = resumed["presentation"]

    if active_p.get("isDisplayLinkPaused") is not False or active_p.get("effectiveVisibility") is not True:
        errors.append("active stage is not visible/unpaused")
    if hidden_end_p.get("isDisplayLinkPaused") is not True or hidden_end_p.get("effectiveVisibility") is not False:
        errors.append("hidden stage is not hidden/paused")
    if resumed_p.get("isDisplayLinkPaused") is not False or resumed_p.get("effectiveVisibility") is not True:
        errors.append("resumed stage is not visible/unpaused")

    if hidden_end_p.get("acceptedTargetCount") != hidden_settled_p.get("acceptedTargetCount"):
        errors.append("display targets advanced while hidden")
    if hidden_end.get("providerFrameCount") != hidden_settled.get("providerFrameCount"):
        errors.append("provider work advanced while hidden")
    if not (
        isinstance(resumed_p.get("acceptedTargetCount"), int)
        and isinstance(hidden_end_p.get("acceptedTargetCount"), int)
        and resumed_p["acceptedTargetCount"] > hidden_end_p["acceptedTargetCount"]
    ):
        errors.append("display targets did not resume")
    if not (
        isinstance(resumed.get("providerFrameCount"), int)
        and isinstance(hidden_end.get("providerFrameCount"), int)
        and resumed["providerFrameCount"] > hidden_end["providerFrameCount"]
    ):
        errors.append("provider work did not resume")
    if report.get("registeredDriverCountAfterCancel") != 0:
        errors.append("runtime driver remained registered after cancel")

    for name, stage in stages.items():
        presentation = stage["presentation"]
        accepted = presentation.get("acceptedTargetCount")
        consumed = presentation.get("consumedTargetCount")
        superseded = presentation.get("supersededPendingTargetCount")
        rejected = presentation.get("rejectedNonmonotonicTargetCount")
        if not all(isinstance(value, int) and value >= 0 for value in (accepted, consumed, superseded, rejected)):
            errors.append(f"invalid counters at {name}")
            continue
        if consumed > accepted:
            errors.append(f"consumed targets exceed accepted targets at {name}")
        if superseded > accepted:
            errors.append(f"superseded targets exceed accepted targets at {name}")
    return errors


def write_log(path: pathlib.Path, completed: subprocess.CompletedProcess[str]) -> None:
    path.write_text(
        f"returnCode={completed.returncode}\n--- stdout ---\n{completed.stdout}"
        f"\n--- stderr ---\n{completed.stderr}"
    )


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
            "xcrun",
            "swift",
            "build",
            "-c",
            "release",
            "--target",
            "FoveaAnimationMacLab",
            "-Xswiftc",
            "-warnings-as-errors",
        ],
        check=False,
    )
    write_log(output / "release-build.log", build)
    if build.returncode != 0:
        print("Release Mac lab build failed", file=sys.stderr)
        return build.returncode or 1

    bin_path = pathlib.Path(
        run(["xcrun", "swift", "build", "-c", "release", "--show-bin-path"]).stdout.strip()
    )
    executable = bin_path / "FoveaAnimationMacLab"
    if not executable.is_file():
        print(f"Mac lab executable missing: {executable}", file=sys.stderr)
        return 1
    executable_identity = file_identity(executable)

    results: list[dict[str, Any]] = []
    runtime_identity: dict[str, Any] | None = None
    all_passed = True
    for index in range(1, FIXED_RUN_COUNT + 1):
        report_path = output / f"run-{index}.json"
        log_path = output / f"run-{index}.log"
        env = os.environ.copy()
        env["NSUnbufferedIO"] = "YES"
        completed = run(
            [str(executable), "--output", str(report_path), "--window-presentation", "nonintrusive"],
            env=env,
            check=False,
        )
        write_log(log_path, completed)
        item: dict[str, Any] = {
            "runIndex": index,
            "returnCode": completed.returncode,
            "log": file_identity(log_path),
        }
        if report_path.is_file():
            item["report"] = file_identity(report_path)
            try:
                report = json.loads(report_path.read_text())
            except (OSError, json.JSONDecodeError) as error:
                item["validationErrors"] = [f"report parse failed: {error}"]
                all_passed = False
            else:
                errors = validate_report(report)
                item["validationErrors"] = errors
                item["activeAcceptedTargetCount"] = report["active"]["presentation"]["acceptedTargetCount"]
                item["hiddenAcceptedTargetCount"] = report["hiddenEnd"]["presentation"]["acceptedTargetCount"]
                item["resumedAcceptedTargetCount"] = report["resumed"]["presentation"]["acceptedTargetCount"]
                item["activeProviderFrameCount"] = report["active"]["providerFrameCount"]
                item["hiddenProviderFrameCount"] = report["hiddenEnd"]["providerFrameCount"]
                item["resumedProviderFrameCount"] = report["resumed"]["providerFrameCount"]
                if runtime_identity is None:
                    runtime_identity = report.get("runtime")
                elif runtime_identity != report.get("runtime"):
                    errors.append("runtime identity changed across fixed runs")
                if errors:
                    all_passed = False
        else:
            item["validationErrors"] = ["report missing"]
            all_passed = False
        if completed.returncode != 0:
            all_passed = False
        results.append(item)

    source_after = git_identity()
    source_unchanged = source_before == source_after
    if not source_unchanged:
        all_passed = False
    manifest = {
        "schemaVersion": 1,
        "studyID": "FOVEA-W5-APPKIT-DISPLAY-LINK-PHYSICAL-MECHANISM-V1",
        "status": "passed-fixed-six-no-retry" if all_passed else "failed-fixed-six-preserved",
        "formalClaimEligible": False,
        "claimBoundary": [
            "physical Mac mechanism and lifecycle evidence only",
            "fixed six runs; failures are preserved and never retried within the capture",
            "no third-party comparator or aggregate ranking",
            "no energy, thermal, memory, startup, codec, or cross-platform superiority claim",
            "display-target counters are distinct from timeline dropped-frame accounting",
        ],
        "runCount": FIXED_RUN_COUNT,
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
    }
    manifest_path = output / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(manifest_path.relative_to(ROOT))
    return 0 if all_passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
