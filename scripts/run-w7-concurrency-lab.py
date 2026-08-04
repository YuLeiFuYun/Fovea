#!/usr/bin/env python3
"""Run the preregistered W7 1,000-request concurrency calibration on iOS Simulator."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any

from comparative_simulator_support import XCODEBUILD_RESOLVED_PACKAGE_FLAGS

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Benchmarks/ComparativeLab/Apps/FoveaComparativeApps.xcodeproj"
PLAN_PATH = ROOT / "Benchmarks/W7ConcurrencyLab/experiment-plan.json"
CLAIMS_PATH = ROOT / "Benchmarks/W7ConcurrencyLab/claim-families.json"
ARTIFACT_ROOT = ROOT / ".artifacts/w7-concurrency-lab"
DERIVED_DATA = ARTIFACT_ROOT / "DerivedData"
BUILD_MANIFEST = DERIVED_DATA / "w7-build-manifest.json"
W7_RUNTIME_IDENTIFIER = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
W7_SIMULATOR_PROFILE_ID = "ios27-simulator-calibration-v1"
W7_SIMULATOR_CHANNEL = "beta"
APPS = {
    "Apple URLSession + URLCache + ImageIO": (
        "AppleNativeComparatorBench", "dev.fovea.comparative.applenative"
    ),
    "Fovea": ("FoveaComparatorBench", "dev.fovea.comparative.fovea"),
    "Nuke": ("NukeComparatorBench", "dev.fovea.comparative.nuke"),
    "Kingfisher": ("KingfisherComparatorBench", "dev.fovea.comparative.kingfisher"),
    "SDWebImage": ("SDWebImageComparatorBench", "dev.fovea.comparative.sdwebimage"),
    "PINRemoteImage": (
        "PINRemoteImageComparatorBench", "dev.fovea.comparative.pinremoteimage"
    ),
    "AlamofireImage": (
        "AlamofireImageComparatorBench",
        "dev.fovea.comparative.alamofireimage",
    ),
}
A_TIER_HEADLESS = [
    "Apple URLSession + URLCache + ImageIO",
    "Fovea",
    "Nuke",
    "Kingfisher",
    "SDWebImage",
    "PINRemoteImage",
]
B_TIER_RETAINED = ["AlamofireImage"]

HARD_CHECKS = {
    "logical-request-count-exact",
    "observation-count-exact",
    "logical-load-preparation-count-exact",
    "single-flight-origin-request-bound",
    "single-flight-preparation-capacity-exact",
    "cancelled-subscriber-count-exact",
    "survivor-completion-count-exact",
    "priority-burst-no-starvation",
    "failed-load-count-zero",
    "target-pixel-invariant",
    "peak-thread-count-bounded",
    "origin-peak-concurrency-bounded",
    "background-probe-bypass-bound",
}
MEASUREMENT_CHECKS = {
    "w7-shared-origin-request-count",
    "w7-shared-preparation-wait-count",
    "w7-baseline-thread-count",
    "w7-peak-thread-count",
    "w7-peak-thread-delta",
    "w7-origin-peak-concurrency",
    "w7-background-probe-newer-bypass-count",
    "w7-p99-logical-latency-ns",
    "w7-throughput-milli-requests-per-second",
    "w7-background-p95-latency-ns",
    "w7-utility-p95-latency-ns",
    "w7-visible-p95-latency-ns",
    "w7-immediate-p95-latency-ns",
}
PHASE_DIAGNOSTIC_CHECKS = {
    "w7-diagnostic-coalescing-construction-ns",
    "w7-diagnostic-coalescing-preparation-ns",
    "w7-diagnostic-coalescing-execution-ns",
    "w7-diagnostic-coalescing-accumulation-ns",
    "w7-diagnostic-blocker-probe-ns",
    "w7-diagnostic-balanced-execution-ns",
    "w7-diagnostic-scheduling-accumulation-ns",
    "w7-diagnostic-coalescing-origin-idle-slot-ns",
    "w7-diagnostic-blocker-probe-origin-idle-slot-ns",
    "w7-diagnostic-balanced-origin-idle-slot-ns",
    "w7-diagnostic-balanced-origin-start-gap-p95-ns",
    "w7-diagnostic-balanced-origin-start-gap-max-ns",
}
MAX_PHASE_DIAGNOSTIC_NANOSECONDS = 2_000_000_000_000


def run(
    command: list[str],
    *,
    env: dict[str, str],
    timeout: int = 600,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
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
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
    ).hexdigest()


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


def simulator(env: dict[str, str]) -> dict[str, str]:
    runtime_records = json.loads(
        run(
            ["xcrun", "simctl", "runtime", "list", "-v", "-j"],
            env=env,
            timeout=60,
        ).stdout
    )
    runtime_matches = [
        (storage_identifier, record)
        for storage_identifier, record in runtime_records.items()
        if record.get("runtimeIdentifier") == W7_RUNTIME_IDENTIFIER
        and record.get("state") == "Ready"
        and record.get("mountPath")
    ]
    if len(runtime_matches) != 1:
        raise RuntimeError(
            "expected exactly one ready mounted iOS 27.0 Simulator runtime, "
            f"found {len(runtime_matches)}"
        )
    storage_identifier, runtime_record = runtime_matches[0]
    version = runtime_record.get("version")
    build = runtime_record.get("build")
    if not isinstance(version, str) or not version or not isinstance(build, str) or not build:
        raise RuntimeError("iOS 27.0 Simulator runtime identity is incomplete")

    data = json.loads(
        run(
            ["xcrun", "simctl", "list", "devices", "available", "-j"], env=env
        ).stdout
    )
    devices = data.get("devices", {}).get(W7_RUNTIME_IDENTIFIER, [])
    matches = [
        item
        for item in devices
        if item.get("name") == "iPhone 17e"
        and item.get("deviceTypeIdentifier")
        == "com.apple.CoreSimulator.SimDeviceType.iPhone-17e"
    ]
    if len(matches) != 1:
        raise RuntimeError(
            f"expected exactly one iOS 27 iPhone 17e simulator, found {len(matches)}"
        )
    selected = matches[0]
    udid = selected["udid"]
    if selected.get("state") != "Booted":
        run(["xcrun", "simctl", "boot", udid], env=env, timeout=120)
    run(["xcrun", "simctl", "bootstatus", udid, "-b"], env=env, timeout=240)
    return {
        "deviceUDID": udid,
        "runtimeIdentifier": W7_RUNTIME_IDENTIFIER,
        "runtimeStorageIdentifier": storage_identifier,
        "runtimeSignatureState": str(runtime_record.get("signatureState", "unknown")),
        "deviceProfileID": W7_SIMULATOR_PROFILE_ID,
        "osVersion": version,
        "osBuild": build,
        "osChannel": W7_SIMULATOR_CHANNEL,
    }



def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_installed_app(
    env: dict[str, str], udid: str, comparator: str
) -> dict[str, str]:
    scheme, bundle = APPS[comparator]
    built_app = DERIVED_DATA / "Build/Products/Release-iphonesimulator" / f"{scheme}.app"
    built_executable = built_app / scheme
    built_resources = built_app / "resource-bundle.json"
    if not built_executable.is_file() or not built_resources.is_file():
        raise RuntimeError(
            f"missing W7 prebuilt app identity for {comparator}: {built_app.relative_to(ROOT)}"
        )
    installed_app = Path(
        run(
            ["xcrun", "simctl", "get_app_container", udid, bundle, "app"],
            env=env,
            timeout=60,
        ).stdout.strip()
    )
    installed_executable = installed_app / scheme
    installed_resources = installed_app / "resource-bundle.json"
    if not installed_executable.is_file() or not installed_resources.is_file():
        raise RuntimeError(f"installed W7 app identity is incomplete: {comparator}")
    identity = {
        "builtExecutableSha256": file_sha256(built_executable),
        "installedExecutableSha256": file_sha256(installed_executable),
        "builtResourceBundleSha256": file_sha256(built_resources),
        "installedResourceBundleSha256": file_sha256(installed_resources),
    }
    if identity["builtExecutableSha256"] != identity["installedExecutableSha256"]:
        raise RuntimeError(
            f"installed W7 executable does not match W7 DerivedData: {comparator}"
        )
    if identity["builtResourceBundleSha256"] != identity["installedResourceBundleSha256"]:
        raise RuntimeError(
            f"installed W7 resources do not match W7 DerivedData: {comparator}"
        )
    return identity


def write_build_manifest(
    *,
    simulator_identity: dict[str, str],
    identity: dict[str, Any],
    plan_digest: str,
    claims_digest: str,
    app_identities: dict[str, dict[str, str]],
) -> None:
    manifest = {
        "schemaVersion": 1,
        "simulatorIdentity": simulator_identity,
        "sourceIdentity": identity,
        "experimentPlanDigest": plan_digest,
        "claimFamilyDigest": claims_digest,
        "apps": app_identities,
    }
    BUILD_MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    temporary = BUILD_MANIFEST.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    temporary.replace(BUILD_MANIFEST)


def verify_build_manifest(
    *,
    env: dict[str, str],
    simulator_identity: dict[str, str],
    selected: list[str],
    identity: dict[str, Any],
    plan_digest: str,
    claims_digest: str,
) -> None:
    if not BUILD_MANIFEST.is_file():
        raise RuntimeError(
            "--skip-build requires a tree-bound W7 build manifest; run without --skip-build"
        )
    manifest = json.loads(BUILD_MANIFEST.read_text())
    expected = {
        "schemaVersion": 1,
        "simulatorIdentity": simulator_identity,
        "sourceIdentity": identity,
        "experimentPlanDigest": plan_digest,
        "claimFamilyDigest": claims_digest,
    }
    drift = {
        key: {"expected": value, "actual": manifest.get(key)}
        for key, value in expected.items()
        if manifest.get(key) != value
    }
    if drift:
        raise RuntimeError(f"W7 prebuilt manifest drifted: {drift}")
    apps = manifest.get("apps")
    if not isinstance(apps, dict):
        raise RuntimeError("W7 prebuilt manifest apps are missing")
    udid = simulator_identity["deviceUDID"]
    for comparator in selected:
        current = verify_installed_app(env, udid, comparator)
        recorded = apps.get(comparator)
        if recorded != current:
            raise RuntimeError(
                f"W7 prebuilt app identity drifted for {comparator}: "
                f"recorded={recorded} current={current}"
            )

def build_install(
    env: dict[str, str],
    simulator_identity: dict[str, str],
    selected: list[str],
    identity: dict[str, Any],
    plan_digest: str,
    claims_digest: str,
) -> None:
    udid = simulator_identity["deviceUDID"]
    DERIVED_DATA.mkdir(parents=True, exist_ok=True)
    app_identities: dict[str, dict[str, str]] = {}
    for comparator in selected:
        scheme, _ = APPS[comparator]
        print(f"Building W7 app: {comparator}", flush=True)
        result = run(
            [
                "xcodebuild",
                *XCODEBUILD_RESOLVED_PACKAGE_FLAGS,
                "-project",
                str(PROJECT),
                "-scheme",
                scheme,
                "-configuration",
                "Release",
                "-destination",
                f"platform=iOS Simulator,id={udid}",
                "-derivedDataPath",
                str(DERIVED_DATA),
                "CODE_SIGNING_ALLOWED=NO",
                "build",
            ],
            env=env,
            timeout=900,
        )
        if "** BUILD SUCCEEDED **" not in result.stdout:
            raise RuntimeError(f"{comparator} W7 build did not report success")
        app = DERIVED_DATA / "Build/Products/Release-iphonesimulator" / f"{scheme}.app"
        run(["xcrun", "simctl", "install", udid, str(app)], env=env, timeout=120)
        app_identities[comparator] = verify_installed_app(env, udid, comparator)
    write_build_manifest(
        simulator_identity=simulator_identity,
        identity=identity,
        plan_digest=plan_digest,
        claims_digest=claims_digest,
        app_identities=app_identities,
    )


def collect_strings(value: Any, output: list[str]) -> None:
    if isinstance(value, str):
        output.append(value)
    elif isinstance(value, dict):
        for child in value.values():
            collect_strings(child, output)
    elif isinstance(value, list):
        for child in value:
            collect_strings(child, output)


def validate(
    data: dict[str, Any],
    comparator: str,
    identity: dict[str, Any],
    plan_digest: str,
    claims_digest: str,
    simulator_identity: dict[str, str],
) -> dict[str, Any]:
    if data.get("schemaVersion") != 3:
        raise RuntimeError("unexpected W7 result schema")
    if data.get("planID") != "FOVEA-W7-CONCURRENCY-V10":
        raise RuntimeError("unexpected W7 plan identity")
    if data.get("harnessIdentity") != identity:
        raise RuntimeError("W7 harness identity mismatch")
    if data.get("experimentPlanDigest") != plan_digest:
        raise RuntimeError("W7 experiment plan digest mismatch")
    if data.get("claimFamilyDigest") != claims_digest:
        raise RuntimeError("W7 claim-family digest mismatch")
    if data.get("executionEnvironment") != "simulator" or data.get("provisional") is not True:
        raise RuntimeError("W7 calibration must remain provisional Simulator evidence")
    environment_record = data.get("environment", {})
    expected_environment = {
        "deviceProfileID": simulator_identity["deviceProfileID"],
        "osVersion": simulator_identity["osVersion"],
        "osBuild": simulator_identity["osBuild"],
        "osChannel": simulator_identity["osChannel"],
    }
    environment_drift = {
        key: {"expected": value, "actual": environment_record.get(key)}
        for key, value in expected_environment.items()
        if environment_record.get(key) != value
    }
    if environment_drift:
        raise RuntimeError(f"W7 Simulator environment identity drifted: {environment_drift}")
    if data.get("workloadID") != "W7-THOUSAND-CONCURRENT-V1":
        raise RuntimeError("W7 workload identity mismatch")
    if data.get("cacheState") != "cold":
        raise RuntimeError("W7 cache-state mismatch")
    if data.get("networkProfile") != "NET-CONSTRAINED-V1":
        raise RuntimeError("W7 network profile mismatch")
    if data.get("comparator", {}).get("name") != comparator:
        raise RuntimeError("W7 comparator identity mismatch")
    artifact = data.get("artifact", {})
    observations = artifact.get("observations", [])
    if not isinstance(observations, list) or len(observations) != 1000:
        raise RuntimeError("W7 must emit exactly 1000 observations")
    if [item.get("sequence") for item in observations] != list(range(1000)):
        raise RuntimeError("W7 observation sequence is not dense and deterministic")
    checks = data.get("checks", [])
    if not isinstance(checks, list):
        raise RuntimeError("W7 checks missing")
    by_id: dict[str, dict[str, Any]] = {}
    for check in checks:
        identifier = check.get("identifier") if isinstance(check, dict) else None
        if not isinstance(identifier, str) or identifier in by_id:
            raise RuntimeError(f"invalid or duplicate W7 check: {identifier}")
        by_id[identifier] = check
    if not HARD_CHECKS <= by_id.keys():
        raise RuntimeError(f"W7 hard checks missing: {sorted(HARD_CHECKS - by_id.keys())}")
    if not MEASUREMENT_CHECKS <= by_id.keys():
        raise RuntimeError(
            f"W7 measurement checks missing: {sorted(MEASUREMENT_CHECKS - by_id.keys())}"
        )
    metrics = {identifier: int(by_id[identifier]["value"]) for identifier in MEASUREMENT_CHECKS}
    diagnostic_ids = PHASE_DIAGNOSTIC_CHECKS.intersection(by_id)
    if diagnostic_ids and diagnostic_ids != PHASE_DIAGNOSTIC_CHECKS:
        raise RuntimeError(
            f"partial W7 phase diagnostics: {sorted(PHASE_DIAGNOSTIC_CHECKS - diagnostic_ids)}"
        )
    phase_diagnostics = {
        identifier: int(by_id[identifier]["value"])
        for identifier in PHASE_DIAGNOSTIC_CHECKS
        if identifier in by_id
    }
    invalid_phase_diagnostics = {
        identifier: value
        for identifier, value in phase_diagnostics.items()
        if value < 0 or value > MAX_PHASE_DIAGNOSTIC_NANOSECONDS
    }
    if invalid_phase_diagnostics:
        raise RuntimeError(
            f"invalid or saturated W7 phase diagnostics: {invalid_phase_diagnostics}"
        )
    background = metrics["w7-background-p95-latency-ns"]
    immediate = metrics["w7-immediate-p95-latency-ns"]
    metrics["w7-immediate-to-background-p95-ratio-ppm"] = (
        0 if background <= 0 else int(round(immediate * 1_000_000 / background))
    )
    strings: list[str] = []
    collect_strings(data, strings)
    if any(token in value for value in strings for token in ("http://", "https://", "Bearer ")):
        raise RuntimeError("W7 result leaks URL or credentials")
    thermal = data.get("thermal")
    if not isinstance(thermal, dict) or not isinstance(thermal.get("remainedNominal"), bool):
        raise RuntimeError("W7 thermal evidence missing")
    return {
        "hardFailures": [
            {
                "check": identifier,
                "value": int(by_id[identifier]["value"]),
            }
            for identifier in sorted(HARD_CHECKS)
            if by_id[identifier].get("passed") is not True
        ],
        "metrics": metrics,
        "phaseDiagnostics": phase_diagnostics,
    }


def run_one(
    *,
    env: dict[str, str],
    udid: str,
    comparator: str,
    run_index: int,
    identity: dict[str, Any],
    plan_digest: str,
    claims_digest: str,
    simulator_identity: dict[str, str],
    phase_diagnostics: bool,
) -> Path:
    _, bundle = APPS[comparator]
    output_name = (
        f"w7-{comparator.lower()}-{run_index:03d}-"
        f"{uuid.uuid4().hex}.json"
    )
    container = Path(
        run(
            ["xcrun", "simctl", "get_app_container", udid, bundle, "data"],
            env=env,
            timeout=60,
        ).stdout.strip()
    )
    source = container / "Documents" / output_name
    source.unlink(missing_ok=True)
    child = env.copy()
    child.update(
        {
            "SIMCTL_CHILD_FOVEA_BENCHMARK_COMMIT": identity["commit"],
            "SIMCTL_CHILD_FOVEA_BENCHMARK_TREE_DIGEST": identity["sourceTreeDigest"],
            "SIMCTL_CHILD_FOVEA_BENCHMARK_DIRTY": (
                "1" if identity["includesWorkingTreeChanges"] else "0"
            ),
            "SIMCTL_CHILD_FOVEA_EXPERIMENT_PLAN_ID": "FOVEA-W7-CONCURRENCY-V10",
            "SIMCTL_CHILD_FOVEA_EXPERIMENT_PLAN_DIGEST": plan_digest,
            "SIMCTL_CHILD_FOVEA_CLAIM_FAMILY_DIGEST": claims_digest,
            "SIMCTL_CHILD_FOVEA_SIMULATOR_PROFILE_ID": simulator_identity["deviceProfileID"],
            "SIMCTL_CHILD_FOVEA_SIMULATOR_OS_VERSION": simulator_identity["osVersion"],
            "SIMCTL_CHILD_FOVEA_SIMULATOR_OS_BUILD": simulator_identity["osBuild"],
            "SIMCTL_CHILD_FOVEA_SIMULATOR_OS_CHANNEL": simulator_identity["osChannel"],
        }
    )
    if phase_diagnostics:
        child["SIMCTL_CHILD_FOVEA_W7_PHASE_DIAGNOSTICS"] = "1"
    launch = run(
        [
            "xcrun",
            "simctl",
            "launch",
            "--terminate-running-process",
            udid,
            bundle,
            "--workload",
            "W7-THOUSAND-CONCURRENT-V1",
            "--cache-state",
            "cold",
            "--network-profile",
            "NET-CONSTRAINED-V1",
            "--run-index",
            str(run_index),
            "--time-scale",
            "1",
            "--output",
            output_name,
        ],
        env=child,
        timeout=60,
    )
    pid = launch.stdout.strip().split(":")[-1].strip()
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline and not source.is_file():
        time.sleep(0.5)
    if not source.is_file():
        logs = run(
            [
                "xcrun",
                "simctl",
                "spawn",
                udid,
                "log",
                "show",
                "--last",
                "10m",
                "--style",
                "compact",
                "--predicate",
                f'processIdentifier == {pid}',
            ],
            env=env,
            timeout=120,
            check=False,
        )
        print(logs.stdout[-20_000:], file=sys.stderr)
        raise RuntimeError(f"missing W7 result after timeout: {comparator}")
    data = json.loads(source.read_text())
    validate(
        data, comparator, identity, plan_digest, claims_digest, simulator_identity
    )
    artifact_name = f"w7-{comparator.lower()}-{run_index:03d}.json"
    destination = ARTIFACT_ROOT / "runs" / comparator / artifact_name
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    return destination


def write_report(
    paths: list[Path],
    selected: list[str],
    identity: dict[str, Any],
    plan_digest: str,
    claims_digest: str,
    simulator_identity: dict[str, str],
) -> dict[str, Any]:
    entries: list[dict[str, Any]] = []
    for path in paths:
        data = json.loads(path.read_text())
        comparator = data["comparator"]["name"]
        validated = validate(
            data, comparator, identity, plan_digest, claims_digest, simulator_identity
        )
        entries.append(
            {
                "comparator": comparator,
                "artifact": str(path.relative_to(ROOT)),
                "hardFailures": validated["hardFailures"],
                "metrics": validated["metrics"],
                "phaseDiagnostics": validated["phaseDiagnostics"],
            }
        )
    fovea_failures = next(
        (item["hardFailures"] for item in entries if item["comparator"] == "Fovea"), []
    )
    report = {
        "schemaVersion": 1,
        "planID": "FOVEA-W7-CONCURRENCY-V10",
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "mode": "simulator-calibration",
        "executionEnvironment": "simulator",
        "provisional": True,
        "releaseClaimPermitted": False,
        "sourceIdentity": identity,
        "experimentPlanDigest": plan_digest,
        "claimFamilyDigest": claims_digest,
        "simulatorIdentity": simulator_identity,
        "buildManifest": str(BUILD_MANIFEST.relative_to(ROOT)),
        "buildManifestSha256": file_sha256(BUILD_MANIFEST),
        "selectedComparators": selected,
        "aTierHeadlessMatrix": A_TIER_HEADLESS,
        "aTierHeadlessComplete": selected == A_TIER_HEADLESS,
        "bTierRetained": B_TIER_RETAINED,
        "bTierIncluded": any(name in selected for name in B_TIER_RETAINED),
        "asyncImageApplicability": "not-applicable-headless-contract",
        "runCount": len(entries),
        "logicalRequestsPerRun": 1000,
        "phaseDiagnosticsEnabled": all(bool(item["phaseDiagnostics"]) for item in entries),
        "foveaHardFailures": fovea_failures,
        "comparatorResults": entries,
        "status": "completed" if not fovea_failures else "fovea-hard-failure",
    }
    ARTIFACT_ROOT.mkdir(parents=True, exist_ok=True)
    if selected == A_TIER_HEADLESS:
        suffix = "a-tier-headless"
    elif selected == A_TIER_HEADLESS + B_TIER_RETAINED:
        suffix = "a-plus-b-headless"
    else:
        suffix = "-".join(name.lower().replace(" ", "-") for name in selected)
    output = ARTIFACT_ROOT / f"calibration-report-{suffix}.json"
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    if selected == A_TIER_HEADLESS:
        (ARTIFACT_ROOT / "calibration-report.json").write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n"
        )
    print(
        f"W7 calibration {report['status']}: runs={len(entries)} "
        f"foveaHardFailures={len(fovea_failures)}"
    )
    print(f"Artifact: {output.relative_to(ROOT)}")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--comparator", action="append", choices=list(APPS))
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--skip-prepare", action="store_true")
    parser.add_argument("--aggregate-only", action="store_true")
    parser.add_argument(
        "--phase-diagnostics",
        action="store_true",
        help="Emit exploratory, non-claim-bearing W7 phase durations.",
    )
    parser.add_argument(
        "--include-b-tier",
        action="store_true",
        help="Append AlamofireImage as separately classified B-tier evidence.",
    )
    args = parser.parse_args()
    if args.comparator:
        selected = args.comparator
    else:
        selected = A_TIER_HEADLESS + (B_TIER_RETAINED if args.include_b_tier else [])
    try:
        env = environment()
        if not args.skip_prepare:
            run(["python3", "scripts/prepare-comparative-app-resources.py"], env=env, timeout=180)
            run(
                [
                    "xcodegen",
                    "generate",
                    "--spec",
                    str(ROOT / "Benchmarks/ComparativeLab/Apps/project.yml"),
                ],
                env=env,
                timeout=120,
            )
        identity = git_identity(env)
        plan_digest = canonical_digest(PLAN_PATH)
        claims_digest = canonical_digest(CLAIMS_PATH)
        if args.aggregate_only:
            paths = [
                ARTIFACT_ROOT / "runs" / comparator / f"w7-{comparator.lower()}-000.json"
                for comparator in selected
            ]
            for path in paths:
                if not path.is_file():
                    raise RuntimeError(f"missing W7 artifact: {path.relative_to(ROOT)}")
            simulator_identity = simulator(env)
            verify_build_manifest(
                env=env,
                simulator_identity=simulator_identity,
                selected=selected,
                identity=identity,
                plan_digest=plan_digest,
                claims_digest=claims_digest,
            )
            report = write_report(
                paths,
                selected,
                identity,
                plan_digest,
                claims_digest,
                simulator_identity,
            )
            return 0 if report["status"] == "completed" else 1
        simulator_identity = simulator(env)
        udid = simulator_identity["deviceUDID"]
        if not args.skip_build:
            build_install(
                env, simulator_identity, selected, identity, plan_digest, claims_digest
            )
        else:
            verify_build_manifest(
                env=env,
                simulator_identity=simulator_identity,
                selected=selected,
                identity=identity,
                plan_digest=plan_digest,
                claims_digest=claims_digest,
            )
        paths: list[Path] = []
        for index, comparator in enumerate(selected, start=1):
            print(f"W7 Simulator {index}/{len(selected)}: {comparator}", flush=True)
            paths.append(
                run_one(
                    env=env,
                    udid=udid,
                    comparator=comparator,
                    run_index=0,
                    identity=identity,
                    plan_digest=plan_digest,
                    claims_digest=claims_digest,
                    simulator_identity=simulator_identity,
                    phase_diagnostics=args.phase_diagnostics,
                )
            )
        report = write_report(
            paths,
            selected,
            identity,
            plan_digest,
            claims_digest,
            simulator_identity,
        )
        return 0 if report["status"] == "completed" else 1
    except Exception as error:
        print(f"W7 concurrency lab failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
