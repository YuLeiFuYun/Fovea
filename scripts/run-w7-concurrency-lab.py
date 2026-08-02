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
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Benchmarks/ComparativeLab/Apps/FoveaComparativeApps.xcodeproj"
PLAN_PATH = ROOT / "Benchmarks/W7ConcurrencyLab/experiment-plan.json"
CLAIMS_PATH = ROOT / "Benchmarks/W7ConcurrencyLab/claim-families.json"
ARTIFACT_ROOT = ROOT / ".artifacts/w7-concurrency-lab"
DERIVED_DATA = ARTIFACT_ROOT / "DerivedData"
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
    "single-flight-origin-request-bound",
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


def simulator(env: dict[str, str]) -> str:
    data = json.loads(
        run(
            ["xcrun", "simctl", "list", "devices", "available", "-j"], env=env
        ).stdout
    )
    runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
    devices = data.get("devices", {}).get(runtime, [])
    selected = next((item for item in devices if item.get("name") == "iPhone 17e"), None)
    if selected is None:
        raise RuntimeError("iOS 27 iPhone 17e simulator is unavailable")
    udid = selected["udid"]
    if selected.get("state") != "Booted":
        run(["xcrun", "simctl", "boot", udid], env=env, timeout=120)
    run(["xcrun", "simctl", "bootstatus", udid, "-b"], env=env, timeout=240)
    return udid


def build_install(env: dict[str, str], udid: str, selected: list[str]) -> None:
    DERIVED_DATA.mkdir(parents=True, exist_ok=True)
    for comparator in selected:
        scheme, _ = APPS[comparator]
        print(f"Building W7 app: {comparator}", flush=True)
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
) -> dict[str, Any]:
    if data.get("schemaVersion") != 3:
        raise RuntimeError("unexpected W7 result schema")
    if data.get("planID") != "FOVEA-W7-CONCURRENCY-V7":
        raise RuntimeError("unexpected W7 plan identity")
    if data.get("harnessIdentity") != identity:
        raise RuntimeError("W7 harness identity mismatch")
    if data.get("experimentPlanDigest") != plan_digest:
        raise RuntimeError("W7 experiment plan digest mismatch")
    if data.get("claimFamilyDigest") != claims_digest:
        raise RuntimeError("W7 claim-family digest mismatch")
    if data.get("executionEnvironment") != "simulator" or data.get("provisional") is not True:
        raise RuntimeError("W7 calibration must remain provisional Simulator evidence")
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
) -> Path:
    _, bundle = APPS[comparator]
    output_name = f"w7-{comparator.lower()}-{run_index:03d}.json"
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
            "SIMCTL_CHILD_FOVEA_EXPERIMENT_PLAN_ID": "FOVEA-W7-CONCURRENCY-V7",
            "SIMCTL_CHILD_FOVEA_EXPERIMENT_PLAN_DIGEST": plan_digest,
            "SIMCTL_CHILD_FOVEA_CLAIM_FAMILY_DIGEST": claims_digest,
        }
    )
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
    validate(data, comparator, identity, plan_digest, claims_digest)
    destination = ARTIFACT_ROOT / "runs" / comparator / output_name
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    return destination


def write_report(
    paths: list[Path],
    selected: list[str],
    identity: dict[str, Any],
    plan_digest: str,
    claims_digest: str,
) -> dict[str, Any]:
    entries: list[dict[str, Any]] = []
    for path in paths:
        data = json.loads(path.read_text())
        comparator = data["comparator"]["name"]
        validated = validate(data, comparator, identity, plan_digest, claims_digest)
        entries.append(
            {
                "comparator": comparator,
                "artifact": str(path.relative_to(ROOT)),
                "hardFailures": validated["hardFailures"],
                "metrics": validated["metrics"],
            }
        )
    fovea_failures = next(
        (item["hardFailures"] for item in entries if item["comparator"] == "Fovea"), []
    )
    report = {
        "schemaVersion": 1,
        "planID": "FOVEA-W7-CONCURRENCY-V7",
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "mode": "simulator-calibration",
        "executionEnvironment": "simulator",
        "provisional": True,
        "releaseClaimPermitted": False,
        "sourceIdentity": identity,
        "experimentPlanDigest": plan_digest,
        "claimFamilyDigest": claims_digest,
        "selectedComparators": selected,
        "aTierHeadlessMatrix": A_TIER_HEADLESS,
        "aTierHeadlessComplete": selected == A_TIER_HEADLESS,
        "bTierRetained": B_TIER_RETAINED,
        "bTierIncluded": any(name in selected for name in B_TIER_RETAINED),
        "asyncImageApplicability": "not-applicable-headless-contract",
        "runCount": len(entries),
        "logicalRequestsPerRun": 1000,
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
            report = write_report(paths, selected, identity, plan_digest, claims_digest)
            return 0 if report["status"] == "completed" else 1
        udid = simulator(env)
        if not args.skip_build:
            build_install(env, udid, selected)
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
                )
            )
        report = write_report(paths, selected, identity, plan_digest, claims_digest)
        return 0 if report["status"] == "completed" else 1
    except Exception as error:
        print(f"W7 concurrency lab failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
