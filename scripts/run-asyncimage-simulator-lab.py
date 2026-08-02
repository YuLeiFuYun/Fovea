#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
import secrets
import signal
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from comparative_simulator_support import (
    assert_measurement_host_quiet,
    ensure_dedicated_simulator,
    recover_dedicated_simulator_user_services,
)

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Benchmarks/ComparativeLab/Apps/FoveaComparativeApps.xcodeproj"
PLAN = ROOT / "Benchmarks/AsyncImageLab/experiment-plan.json"
APPLICABILITY = ROOT / "Benchmarks/AsyncImageLab/applicability.json"
CLAIMS = ROOT / "Benchmarks/AsyncImageLab/claim-families.json"
ARTIFACT_ROOT = ROOT / ".artifacts/asyncimage-lab"
DERIVED_DATA = ARTIFACT_ROOT / "DerivedData"
INSTALL_STAGING = ARTIFACT_ROOT / "InstallStaging"
RUNNER_LOCK = ARTIFACT_ROOT / "runner.lock"
PENDING_RUN_ROOT = ARTIFACT_ROOT / "pending-runs"
FAILED_RUN_ROOT = ARTIFACT_ROOT / "failed-runs"
PLAN_ID = "FOVEA-SWIFTUI-SURFACE-LAB-V5"
SCHEMA_VERSION = 5
PAIRED_BLOCKS = 5
SURFACES = {
    "Apple AsyncImage": ("AsyncImageComparatorBench", "dev.fovea.comparative.asyncimage"),
    "Fovea": ("FoveaSwiftUIComparatorBench", "dev.fovea.comparative.foveaswiftui"),
}
PAIRED_ORDERS = (
    ("Apple AsyncImage", "Fovea"),
    ("Fovea", "Apple AsyncImage"),
)
WORKLOADS = {
    "W1-SCROLL-V1": 0.1,
    "W2-HERO-V1": 1.0,
    "W10-SWIFTUI-IDENTITY-CHURN-V1": 1.0,
}


def run(
    command: list[str],
    *,
    env: dict[str, str],
    timeout: int = 600,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                process.communicate(timeout=1)
            except subprocess.TimeoutExpired:
                # A CoreSimulator client can remain in uninterruptible kernel I/O.
                # Close our pipe ends and fail the runner without waiting forever;
                # launchd will reap the orphan if the kernel call eventually returns.
                if process.stdout is not None:
                    process.stdout.close()
                if process.stderr is not None:
                    process.stderr.close()
        raise subprocess.TimeoutExpired(
            command,
            timeout,
            output=error.output,
            stderr=error.stderr,
        ) from error
    result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    if check and result.returncode != 0:
        print(result.stdout[-12_000:], file=sys.stderr)
        print(result.stderr[-12_000:], file=sys.stderr)
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(command[:6])}")
    return result


def environment() -> dict[str, str]:
    env = os.environ.copy()
    if not env.get("DEVELOPER_DIR"):
        env["DEVELOPER_DIR"] = subprocess.run(
            [str(ROOT / "scripts/select-xcode.sh")],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()
    return env


def canonical_digest(path: Path) -> str:
    value = json.loads(path.read_text())
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def related_result_files(source: Path) -> list[Path]:
    candidates = [
        source,
        source.with_name(source.name.replace(".json", ".timeline.json")),
        source.with_name(source.name.replace(".json", ".diagnostics.json")),
    ]
    return [path for path in candidates if path.is_file()]


def stage_raw_run(
    source: Path,
    *,
    comparator: str,
    workload: str,
    run_index: int,
    order_position: int,
    run_nonce: str,
) -> tuple[Path, Path]:
    pending = PENDING_RUN_ROOT / run_nonce
    if pending.exists():
        shutil.rmtree(pending)
    pending.mkdir(parents=True, exist_ok=False)
    for path in related_result_files(source):
        shutil.copy2(path, pending / path.name)
    context = {
        "comparator": comparator,
        "workload": workload,
        "runIndex": run_index,
        "orderPosition": order_position,
        "runNonce": run_nonce,
        "capturedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "sourceContainerPath": str(source.parent),
    }
    (pending / "capture-context.json").write_text(
        json.dumps(context, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    )
    staged_source = pending / source.name
    if not staged_source.is_file():
        raise RuntimeError(f"failed to stage raw SwiftUI result: {source.name}")
    return pending, staged_source


def quarantine_failed_run(pending: Path, *, run_nonce: str) -> Path:
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    FAILED_RUN_ROOT.mkdir(parents=True, exist_ok=True)
    destination = FAILED_RUN_ROOT / f"{timestamp}-{run_nonce}"
    pending.replace(destination)
    return destination


def discard_pending_run(pending: Path) -> None:
    shutil.rmtree(pending, ignore_errors=True)


def protocol_digests() -> tuple[str, str, str]:
    return canonical_digest(PLAN), canonical_digest(APPLICABILITY), canonical_digest(CLAIMS)


def git_identity(env: dict[str, str]) -> dict[str, Any]:
    head = run(["git", "rev-parse", "HEAD"], env=env).stdout.strip()
    dirty = bool(run(["git", "status", "--porcelain=v1"], env=env).stdout.strip())
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
        ["git", "ls-files", "--others", "--exclude-standard", "-z"], env=env
    ).stdout.split("\0")
    for relative in sorted(value for value in untracked if value):
        path = ROOT / relative
        if path.is_file() and not path.is_symlink():
            digest.update(relative.encode() + b"\0" + path.read_bytes() + b"\0")
    return {
        "commit": head,
        "sourceTreeDigest": digest.hexdigest(),
        "includesWorkingTreeChanges": dirty,
    }


def simulator(
    env: dict[str, str], *, require_terminal_boot: bool = True
) -> str:
    return ensure_dedicated_simulator(
        run_command=run,
        env=env,
        root=ROOT,
        require_terminal_boot=require_terminal_boot,
    )


def app_path(comparator: str) -> Path:
    scheme, _ = SURFACES[comparator]
    return (
        DERIVED_DATA
        / scheme
        / "Build/Products/Release-iphonesimulator"
        / f"{scheme}.app"
    )


def build_apps(env: dict[str, str], selected: list[str]) -> dict[str, Path]:
    run(["python3", "scripts/prepare-comparative-app-resources.py"], env=env, timeout=180)
    run(
        ["xcodegen", "generate", "--spec", str(ROOT / "Benchmarks/ComparativeLab/Apps/project.yml")],
        env=env,
        timeout=120,
    )
    apps: dict[str, Path] = {}
    for comparator in selected:
        scheme, _ = SURFACES[comparator]
        result = run(
            [
                "xcodebuild",
                "-project",
                str(PROJECT),
                "-scheme",
                scheme,
                "-configuration",
                "Release",
                "-destination",
                "generic/platform=iOS Simulator",
                "-derivedDataPath",
                str(DERIVED_DATA / scheme),
                "CODE_SIGNING_ALLOWED=NO",
                "build",
            ],
            env=env,
            timeout=900,
        )
        if "** BUILD SUCCEEDED **" not in result.stdout:
            raise RuntimeError(f"{comparator} SwiftUI surface build did not report success")
        apps[comparator] = app_path(comparator)
    return apps


def _directory_size(path: Path) -> int:
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def stage_installable_app(
    env: dict[str, str],
    comparator: str,
    source: Path,
) -> Path:
    scheme, _ = SURFACES[comparator]
    destination = INSTALL_STAGING / f"{scheme}.app"
    INSTALL_STAGING.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(destination, ignore_errors=True)
    run(
        ["ditto", "--noextattr", "--norsrc", str(source), str(destination)],
        env=env,
        timeout=180,
    )
    run(["xattr", "-cr", str(destination)], env=env, timeout=60)
    run(
        [
            "codesign",
            "--force",
            "--deep",
            "--sign",
            "-",
            "--timestamp=none",
            str(destination),
        ],
        env=env,
        timeout=120,
    )
    run(
        ["codesign", "--verify", "--deep", "--strict", str(destination)],
        env=env,
        timeout=120,
    )
    executable = destination / scheme
    manifest_path = INSTALL_STAGING / f"{scheme}.json"
    manifest_path.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "comparator": comparator,
                "sourceApp": str(source.relative_to(ROOT)),
                "stagedApp": str(destination.relative_to(ROOT)),
                "sourceBytes": _directory_size(source),
                "stagedBytes": _directory_size(destination),
                "sourceExecutableSHA256": hashlib.sha256((source / scheme).read_bytes()).hexdigest(),
                "stagedExecutableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
                "normalization": [
                    "ditto-noextattr-norsrc",
                    "xattr-clear-recursive",
                    "post-resource-ad-hoc-codesign",
                    "codesign-deep-strict-verified",
                ],
            },
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )
    return destination


def existing_apps(env: dict[str, str], selected: list[str]) -> dict[str, Path]:
    sources = {comparator: app_path(comparator) for comparator in selected}
    missing = [str(path.relative_to(ROOT)) for path in sources.values() if not path.is_dir()]
    if missing:
        raise RuntimeError(f"missing prebuilt SwiftUI surface apps: {missing}")
    return {
        comparator: stage_installable_app(env, comparator, source)
        for comparator, source in sources.items()
    }


def install_staged_app(
    env: dict[str, str],
    udid: str,
    comparator: str,
    app: Path,
) -> Path:
    _, bundle = SURFACES[comparator]
    try:
        run(["xcrun", "simctl", "install", udid, str(app)], env=env, timeout=120)
        container = run(
            ["xcrun", "simctl", "get_app_container", udid, bundle, "data"],
            env=env,
            timeout=60,
        ).stdout.strip()
    except subprocess.TimeoutExpired:
        recover_dedicated_simulator_user_services(
            udid=udid,
            root=ROOT,
            reason=f"SwiftUI overlay install timeout: {comparator}",
        )
        raise
    if not container:
        raise RuntimeError(f"SwiftUI overlay install produced no data container: {comparator}")
    return Path(container)


def reinstall_app(
    env: dict[str, str],
    udid: str,
    comparator: str,
    app: Path,
) -> Path:
    _, bundle = SURFACES[comparator]
    run(["xcrun", "simctl", "terminate", udid, bundle], env=env, timeout=60, check=False)
    run(["xcrun", "simctl", "uninstall", udid, bundle], env=env, timeout=60, check=False)
    try:
        run(["xcrun", "simctl", "install", udid, str(app)], env=env, timeout=120)
    except subprocess.TimeoutExpired:
        recover_dedicated_simulator_user_services(
            udid=udid,
            root=ROOT,
            reason=f"SwiftUI install timeout: {comparator}",
        )
        raise
    return Path(
        run(
            ["xcrun", "simctl", "get_app_container", udid, bundle, "data"],
            env=env,
            timeout=60,
        ).stdout.strip()
    )


def slug(comparator: str) -> str:
    return comparator.lower().replace(" ", "-")


def result_name(comparator: str, workload: str, run_index: int) -> str:
    return f"{slug(comparator)}-{workload.lower()}-{run_index:03d}.json"


def result_path(comparator: str, workload: str, run_index: int) -> Path:
    return ARTIFACT_ROOT / "runs" / comparator / workload / result_name(
        comparator, workload, run_index
    )


def validate(
    data: dict[str, Any],
    comparator: str,
    workload: str,
    run_index: int,
    order_position: int,
    identity: dict[str, Any],
    plan_digest: str,
    applicability_digest: str,
    claim_family_digest: str,
    expected_nonce: str | None = None,
) -> None:
    if data.get("schemaVersion") != SCHEMA_VERSION or data.get("planID") != PLAN_ID:
        raise RuntimeError("unexpected SwiftUI surface result identity")
    if data.get("workloadID") != workload:
        raise RuntimeError("SwiftUI surface workload mismatch")
    if data.get("runIndex") != run_index or data.get("orderPosition") != order_position:
        raise RuntimeError("SwiftUI surface paired-block coordinates mismatch")
    nonce = data.get("runNonce")
    if (
        not isinstance(nonce, str)
        or len(nonce) != 32
        or any(character not in "0123456789abcdef" for character in nonce)
    ):
        raise RuntimeError("SwiftUI surface run nonce is invalid")
    if expected_nonce is not None and nonce != expected_nonce:
        raise RuntimeError("SwiftUI surface paired-block nonce mismatch")
    if data.get("harnessIdentity") != identity:
        raise RuntimeError("SwiftUI surface harness identity mismatch")
    if (
        data.get("experimentPlanDigest") != plan_digest
        or data.get("applicabilityDigest") != applicability_digest
        or data.get("claimFamilyDigest") != claim_family_digest
    ):
        raise RuntimeError("SwiftUI surface protocol digest mismatch")
    comparator_identity = data.get("comparator", {})
    if comparator_identity.get("name") != comparator:
        raise RuntimeError("SwiftUI surface comparator mismatch")
    if comparator == "Apple AsyncImage":
        if comparator_identity.get("sourceKind") != "platform-build":
            raise RuntimeError("AsyncImage platform identity is missing")
        platform = comparator_identity.get("platformBuild", {})
        if not all(
            isinstance(platform.get(key), str) and platform[key]
            for key in ("xcodeBuild", "osBuild", "deviceProfileID")
        ):
            raise RuntimeError("AsyncImage platform build binding is incomplete")
    else:
        if comparator_identity.get("sourceKind") != "git-commit":
            raise RuntimeError("Fovea SwiftUI Git identity is missing")
        if comparator_identity.get("exactCommit") != identity["commit"]:
            raise RuntimeError("Fovea SwiftUI commit identity mismatch")
        if comparator_identity.get("sourceTreeDigest") != identity["sourceTreeDigest"]:
            raise RuntimeError("Fovea SwiftUI tree identity mismatch")
    if data.get("executionEnvironment") != "simulator" or data.get("provisional") is not True:
        raise RuntimeError("SwiftUI simulator evidence must remain provisional")
    thermal = data.get("thermal", {})
    if thermal.get("stateAtStart") != "nominal":
        raise RuntimeError("SwiftUI surface run did not start at nominal thermal state")
    origin = data.get("originMetrics", {})
    if not isinstance(origin.get("requestCount"), int) or origin["requestCount"] <= 0:
        raise RuntimeError("SwiftUI surface origin observed no requests")
    if origin.get("completedRequestCount", 0) + origin.get("stoppedRequestCount", 0) > origin["requestCount"]:
        raise RuntimeError("SwiftUI surface origin terminal counts exceed request count")
    measurements = data.get("measurements", {})
    if not isinstance(measurements.get("successCount"), int) or measurements["successCount"] <= 0:
        raise RuntimeError("SwiftUI surface observed no success phase")
    visible_latency = measurements.get("p95SuccessLatencyNanoseconds")
    terminal_latency = measurements.get("p95TerminalLatencyNanoseconds")
    terminal_count = measurements.get("terminalCount")
    terminal_without_visible = measurements.get("terminalWithoutVisibleCount")
    if not isinstance(visible_latency, int) or not isinstance(terminal_latency, int):
        raise RuntimeError("SwiftUI visible or terminal latency is missing")
    if not isinstance(terminal_count, int) or terminal_count <= 0:
        raise RuntimeError("SwiftUI surface observed no terminal phase")
    if terminal_without_visible != 0:
        raise RuntimeError("SwiftUI terminal phase was recorded before visible success")
    if terminal_count > measurements["successCount"]:
        raise RuntimeError("SwiftUI terminal count exceeds visible-success count")
    if comparator == "Apple AsyncImage" and terminal_count != measurements["successCount"]:
        raise RuntimeError("AsyncImage visible and terminal counts must be identical")
    checks = data.get("checks", [])
    if any(not check.get("passed") for check in checks):
        failed = [check.get("identifier") for check in checks if not check.get("passed")]
        raise RuntimeError(f"SwiftUI surface hard checks failed: {failed}")
    limitations = data.get("limitations")
    if not isinstance(limitations, list) or not limitations:
        raise RuntimeError("SwiftUI surface limitations must remain explicit")


def expected_order(run_index: int) -> tuple[str, str]:
    return PAIRED_ORDERS[run_index % len(PAIRED_ORDERS)]


def expected_specs(
    selected_comparators: list[str], selected_workloads: list[str]
) -> list[tuple[str, str, int, int]]:
    selected = set(selected_comparators)
    specs: list[tuple[str, str, int, int]] = []
    for run_index in range(PAIRED_BLOCKS):
        order = expected_order(run_index)
        for workload in selected_workloads:
            for order_position, comparator in enumerate(order):
                if comparator in selected:
                    specs.append((comparator, workload, run_index, order_position))
    return specs


def calibration_summary(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    summaries: list[dict[str, Any]] = []
    for comparator in SURFACES:
        for workload in WORKLOADS:
            group = [
                record
                for record in records
                if record["comparator"]["name"] == comparator
                and record["workloadID"] == workload
            ]
            if not group:
                continue
            summaries.append(
                {
                    "comparator": comparator,
                    "workloadID": workload,
                    "pairedBlockCount": len(group),
                    "medianHitchExcessNanoseconds": int(
                        statistics.median(
                            record["processMetrics"]["hitchExcessNanoseconds"]
                            for record in group
                        )
                    ),
                    "medianPhysicalFootprintDeltaBytes": int(
                        statistics.median(
                            record["processMetrics"]["physicalFootprintDeltaBytes"]
                            for record in group
                        )
                    ),
                    "medianP95VisibleSuccessLatencyNanoseconds": int(
                        statistics.median(
                            record["measurements"]["p95SuccessLatencyNanoseconds"]
                            for record in group
                            if record["measurements"]["p95SuccessLatencyNanoseconds"] is not None
                        )
                    ),
                    "medianP95TerminalPhaseLatencyNanoseconds": int(
                        statistics.median(
                            record["measurements"]["p95TerminalLatencyNanoseconds"]
                            for record in group
                            if record["measurements"]["p95TerminalLatencyNanoseconds"] is not None
                        )
                    ),
                    "maximumStaleSuccessCount": max(
                        record["measurements"]["staleSuccessCount"] for record in group
                    ),
                }
            )
    return summaries


def write_report(
    paths: list[Path],
    selected_comparators: list[str],
    selected_workloads: list[str],
    identity: dict[str, Any],
    plan_digest: str,
    applicability_digest: str,
    claim_family_digest: str,
) -> dict[str, Any]:
    records = [json.loads(path.read_text()) for path in paths]
    expected = expected_specs(selected_comparators, selected_workloads)
    coordinates = {
        (
            record["comparator"]["name"],
            record["workloadID"],
            record["runIndex"],
            record["orderPosition"],
        )
        for record in records
    }
    paired_blocks_complete = coordinates == set(expected)
    if set(selected_comparators) == set(SURFACES):
        for run_index in range(PAIRED_BLOCKS):
            order = expected_order(run_index)
            for workload in selected_workloads:
                group = [
                    record
                    for record in records
                    if record["runIndex"] == run_index and record["workloadID"] == workload
                ]
                if len(group) != 2:
                    paired_blocks_complete = False
                    continue
                if len({record["runNonce"] for record in group}) != 1:
                    paired_blocks_complete = False
                observed_order = tuple(
                    record["comparator"]["name"]
                    for record in sorted(group, key=lambda value: value["orderPosition"])
                )
                if observed_order != order:
                    paired_blocks_complete = False
    hard_failure_count = sum(
        1 for record in records for check in record["checks"] if not check["passed"]
    )
    report = {
        "schemaVersion": SCHEMA_VERSION,
        "planID": PLAN_ID,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "mode": "simulator-calibration",
        "sourceIdentity": identity,
        "sourceIdentityStableThroughRun": True,
        "experimentPlanDigest": plan_digest,
        "applicabilityDigest": applicability_digest,
        "claimFamilyDigest": claim_family_digest,
        "comparators": selected_comparators,
        "pairedBlockCount": PAIRED_BLOCKS,
        "pairedBlocksComplete": paired_blocks_complete,
        "runCount": len(records),
        "expectedRunCount": len(expected),
        "workloads": selected_workloads,
        "hardFailureCount": hard_failure_count,
        "calibrationSummary": calibration_summary(records),
        "releaseClaimPermitted": False,
        "status": "completed" if paired_blocks_complete and hard_failure_count == 0 else "failed",
        "runArtifacts": [str(path.relative_to(ROOT)) for path in paths],
    }
    ARTIFACT_ROOT.mkdir(parents=True, exist_ok=True)
    destination = ARTIFACT_ROOT / "calibration-report.json"
    destination.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        f"SwiftUI surface calibration completed: runs={report['runCount']} "
        f"pairedBlocksComplete={report['pairedBlocksComplete']} "
        f"hardFailures={report['hardFailureCount']}"
    )
    print(f"Artifact: {destination.relative_to(ROOT)}")
    return report


def acquire_runner_lock() -> int:
    ARTIFACT_ROOT.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(RUNNER_LOCK, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as error:
        os.close(descriptor)
        raise RuntimeError(
            "another SwiftUI surface runner already owns the simulator evidence lock"
        ) from error
    os.ftruncate(descriptor, 0)
    os.write(descriptor, f"pid={os.getpid()}\n".encode())
    return descriptor


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run paired Apple AsyncImage and Fovea SwiftUI calibration blocks."
    )
    parser.add_argument("--comparator", action="append", choices=list(SURFACES))
    parser.add_argument("--workload", action="append", choices=list(WORKLOADS))
    parser.add_argument(
        "--build-only",
        action="store_true",
        help="Build selected SwiftUI apps without running paired measurements.",
    )
    parser.add_argument(
        "--initialize-simulator-only",
        action="store_true",
        help="Initialize and validate the exact-build dedicated simulator without building or measuring.",
    )
    parser.add_argument(
        "--install-only",
        action="store_true",
        help="Install selected prebuilt SwiftUI apps without running measurements.",
    )
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--aggregate-only", action="store_true")
    args = parser.parse_args()
    exclusive_modes = sum(
        bool(value)
        for value in (
            args.build_only,
            args.initialize_simulator_only,
            args.install_only,
            args.aggregate_only,
        )
    )
    if exclusive_modes > 1:
        parser.error(
            "--build-only, --initialize-simulator-only, --install-only and --aggregate-only are mutually exclusive"
        )
    if (args.build_only or args.initialize_simulator_only or args.install_only) and args.skip_build:
        parser.error("preparation-only modes cannot be combined with --skip-build")
    if (
        not args.build_only
        and not args.initialize_simulator_only
        and not args.install_only
        and not args.aggregate_only
        and not args.skip_build
    ):
        parser.error("measurement runs require --skip-build; use --build-only first")
    selected_comparators = list(dict.fromkeys(args.comparator or list(SURFACES)))
    selected_workloads = list(dict.fromkeys(args.workload or list(WORKLOADS)))
    lock_descriptor: int | None = None
    try:
        lock_descriptor = acquire_runner_lock()
        env = environment()
        run(["python3", "scripts/check-asyncimage-lab-plan.py"], env=env, timeout=120)
        specs = expected_specs(selected_comparators, selected_workloads)
        if args.initialize_simulator_only:
            udid = simulator(env)
            print(f"Dedicated simulator initialized: device={udid} measurements=0")
            return 0
        if args.install_only:
            udid = simulator(env)
            apps = existing_apps(env, selected_comparators)
            for comparator in selected_comparators:
                install_staged_app(env, udid, comparator, apps[comparator])
                print(f"Installed prebuilt SwiftUI app: {comparator}", flush=True)
            print(
                "Prebuilt SwiftUI surface apps installed: "
                f"comparators={len(apps)} device={udid} measurements=0"
            )
            return 0
        if args.aggregate_only:
            identity = git_identity(env)
            plan_digest, applicability_digest, claim_family_digest = protocol_digests()
            paths: list[Path] = []
            for comparator, workload, run_index, order_position in specs:
                path = result_path(comparator, workload, run_index)
                if not path.is_file():
                    raise RuntimeError(f"missing SwiftUI surface artifact: {path.relative_to(ROOT)}")
                validate(
                    json.loads(path.read_text()),
                    comparator,
                    workload,
                    run_index,
                    order_position,
                    identity,
                    plan_digest,
                    applicability_digest,
                    claim_family_digest,
                )
                paths.append(path)
            report = write_report(
                paths,
                selected_comparators,
                selected_workloads,
                identity,
                plan_digest,
                applicability_digest,
                claim_family_digest,
            )
            return 0 if report["status"] == "completed" else 1

        if args.build_only:
            apps = build_apps(env, selected_comparators)
            print(
                "SwiftUI surface apps built: "
                f"comparators={len(apps)} installations=0 measurements=0"
            )
            return 0
        udid = simulator(env)
        apps = (
            existing_apps(env, selected_comparators)
            if args.skip_build
            else build_apps(env, selected_comparators)
        )
        assert_measurement_host_quiet(root=ROOT)
        run(["python3", "scripts/check-asyncimage-lab-plan.py"], env=env, timeout=120)
        identity = git_identity(env)
        plan_digest, applicability_digest, claim_family_digest = protocol_digests()
        child = env.copy()
        child.update(
            {
                "SIMCTL_CHILD_FOVEA_BENCHMARK_COMMIT": identity["commit"],
                "SIMCTL_CHILD_FOVEA_BENCHMARK_TREE_DIGEST": identity["sourceTreeDigest"],
                "SIMCTL_CHILD_FOVEA_BENCHMARK_DIRTY": "1"
                if identity["includesWorkingTreeChanges"]
                else "0",
                "SIMCTL_CHILD_FOVEA_EXPERIMENT_PLAN_DIGEST": plan_digest,
                "SIMCTL_CHILD_FOVEA_APPLICABILITY_DIGEST": applicability_digest,
                "SIMCTL_CHILD_FOVEA_CLAIM_FAMILY_DIGEST": claim_family_digest,
            }
        )
        total = len(specs)
        completed = 0
        paths: list[Path] = []
        selected = set(selected_comparators)
        for run_index in range(PAIRED_BLOCKS):
            order = expected_order(run_index)
            for workload in selected_workloads:
                run_nonce = secrets.token_hex(16)
                for order_position, comparator in enumerate(order):
                    if comparator not in selected:
                        continue
                    completed += 1
                    _, bundle = SURFACES[comparator]
                    container = reinstall_app(env, udid, comparator, apps[comparator])
                    name = result_name(comparator, workload, run_index)
                    source = container / "Documents" / name
                    source.unlink(missing_ok=True)
                    print(
                        f"SwiftUI paired run {completed}/{total}: block={run_index} "
                        f"order={order_position} {comparator} {workload}",
                        flush=True,
                    )
                    launch_command = [
                        "xcrun",
                        "simctl",
                        "launch",
                        "--terminate-running-process",
                        udid,
                        bundle,
                        "--workload",
                        workload,
                        "--network-profile",
                        "NET-LOCAL-V1",
                        "--run-index",
                        str(run_index),
                        "--order-position",
                        str(order_position),
                        "--run-nonce",
                        run_nonce,
                        "--time-scale",
                        str(WORKLOADS[workload]),
                        "--output",
                        name,
                    ]
                    try:
                        run(launch_command, env=child, timeout=60)
                    except subprocess.TimeoutExpired:
                        # Xcode beta 的 simctl launch 偶尔在目标 App 已写完结果并退出后
                        # 仍不返回。结果文件与严格身份校验才是完成事实；不能把控制端
                        # 挂起误判成基准失败。
                        pass
                    expected_outputs = [source]
                    if comparator == "Fovea":
                        if child.get("SIMCTL_CHILD_FOVEA_BENCHMARK_TIMELINE") == "1":
                            expected_outputs.append(
                                source.with_name(source.name.replace(".json", ".timeline.json"))
                            )
                        if child.get("SIMCTL_CHILD_FOVEA_BENCHMARK_DIAGNOSTICS") == "1":
                            expected_outputs.append(
                                source.with_name(source.name.replace(".json", ".diagnostics.json"))
                            )
                    deadline = time.monotonic() + 180
                    while time.monotonic() < deadline and not all(
                        path.is_file() for path in expected_outputs
                    ):
                        time.sleep(0.5)
                    missing_outputs = [path for path in expected_outputs if not path.is_file()]
                    if missing_outputs:
                        if source.is_file():
                            pending, _ = stage_raw_run(
                                source,
                                comparator=comparator,
                                workload=workload,
                                run_index=run_index,
                                order_position=order_position,
                                run_nonce=run_nonce,
                            )
                            failed = quarantine_failed_run(pending, run_nonce=run_nonce)
                            missing_names = ", ".join(path.name for path in missing_outputs)
                            raise RuntimeError(
                                "incomplete SwiftUI raw result preserved at "
                                f"{failed.relative_to(ROOT)}; missing: {missing_names}"
                            )
                        raise RuntimeError(
                            f"missing SwiftUI surface result after timeout: {name}"
                        )
                    pending, staged_source = stage_raw_run(
                        source,
                        comparator=comparator,
                        workload=workload,
                        run_index=run_index,
                        order_position=order_position,
                        run_nonce=run_nonce,
                    )
                    try:
                        data = json.loads(staged_source.read_text())
                        validate(
                            data,
                            comparator,
                            workload,
                            run_index,
                            order_position,
                            identity,
                            plan_digest,
                            applicability_digest,
                            claim_family_digest,
                            run_nonce,
                        )
                    except Exception as error:
                        failed = quarantine_failed_run(pending, run_nonce=run_nonce)
                        raise RuntimeError(
                            f"SwiftUI raw failure preserved at {failed.relative_to(ROOT)}: {error}"
                        ) from error

                    destination = result_path(comparator, workload, run_index)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(staged_source, destination)
                    for suffix in (".timeline.json", ".diagnostics.json"):
                        staged_sidecar = staged_source.with_name(
                            staged_source.name.replace(".json", suffix)
                        )
                        sidecar_destination = destination.with_name(
                            destination.name.replace(".json", suffix)
                        )
                        if staged_sidecar.is_file():
                            shutil.copy2(staged_sidecar, sidecar_destination)
                        else:
                            # A non-diagnostic run must not inherit an older optional sidecar
                            # with the same block filename and a different source digest/schema.
                            sidecar_destination.unlink(missing_ok=True)
                    discard_pending_run(pending)
                    paths.append(destination)

        final_identity = git_identity(env)
        if final_identity != identity:
            raise RuntimeError(
                "source identity changed during SwiftUI paired blocks; artifacts retained for "
                "diagnosis but aggregate rejected"
            )
        if protocol_digests() != (
            plan_digest,
            applicability_digest,
            claim_family_digest,
        ):
            raise RuntimeError("SwiftUI protocol files changed during paired blocks")
        report = write_report(
            paths,
            selected_comparators,
            selected_workloads,
            identity,
            plan_digest,
            applicability_digest,
            claim_family_digest,
        )
        return 0 if report["status"] == "completed" else 1
    except Exception as error:
        print(f"SwiftUI surface simulator lab failed: {error}", file=sys.stderr)
        return 1
    finally:
        if lock_descriptor is not None:
            fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
            os.close(lock_descriptor)


if __name__ == "__main__":
    raise SystemExit(main())
