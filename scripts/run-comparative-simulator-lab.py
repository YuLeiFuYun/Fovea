#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import signal
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from comparative_simulator_support import (
    SIMULATOR_RUNTIME_BUILD,
    SIMULATOR_RUNTIME_VERSION,
    XCODEBUILD_RESOLVED_PACKAGE_FLAGS,
    assert_measurement_host_quiet,
    ensure_dedicated_simulator,
    recover_dedicated_simulator_user_services,
)

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Benchmarks/ComparativeLab/Apps/FoveaComparativeApps.xcodeproj"
ARTIFACT_ROOT = ROOT / ".artifacts/comparative-simulator-lab"
DERIVED_DATA = ARTIFACT_ROOT / "DerivedData"
APPS = {
    "Apple URLSession + URLCache + ImageIO": (
        "AppleNativeComparatorBench", "dev.fovea.comparative.applenative"
    ),
    "Fovea": ("FoveaComparatorBench", "dev.fovea.comparative.fovea"),
    "Nuke": ("NukeComparatorBench", "dev.fovea.comparative.nuke"),
    "Kingfisher": ("KingfisherComparatorBench", "dev.fovea.comparative.kingfisher"),
    "SDWebImage": ("SDWebImageComparatorBench", "dev.fovea.comparative.sdwebimage"),
    "AlamofireImage": ("AlamofireImageComparatorBench", "dev.fovea.comparative.alamofireimage"),
    "PINRemoteImage": (
        "PINRemoteImageComparatorBench", "dev.fovea.comparative.pinremoteimage"
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
SIMULATOR_IDENTITY = {
    "deviceProfileID": "ios26-4-simulator-calibration-v1",
    "osVersion": SIMULATOR_RUNTIME_VERSION,
    "osBuild": SIMULATOR_RUNTIME_BUILD,
    "osChannel": "stable",
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
            [str(ROOT / "scripts/select-xcode.sh")], cwd=ROOT, text=True, capture_output=True, check=True
        ).stdout.strip()
    return env


def git_identity(env: dict[str, str]) -> dict[str, Any]:
    head = run(["git", "rev-parse", "HEAD"], env=env).stdout.strip()
    dirty = bool(run(["git", "status", "--porcelain=v1"], env=env).stdout.strip())
    digest = hashlib.sha256()
    digest.update(b"fovea-worktree-v1\0" + head.encode())
    digest.update(subprocess.run(["git", "diff", "--binary", "HEAD"], cwd=ROOT, stdout=subprocess.PIPE, check=True).stdout)
    untracked = run(["git", "ls-files", "--others", "--exclude-standard", "-z"], env=env).stdout.split("\0")
    for relative in sorted(x for x in untracked if x):
        path = ROOT / relative
        if path.is_file() and not path.is_symlink():
            digest.update(relative.encode() + b"\0" + path.read_bytes() + b"\0")
    return {"commit": head, "sourceTreeDigest": digest.hexdigest(), "includesWorkingTreeChanges": dirty}


def canonical_digest(path: Path) -> str:
    value = json.loads(path.read_text())
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def simulator(
    env: dict[str, str], *, require_terminal_boot: bool = True
) -> str:
    return ensure_dedicated_simulator(
        run_command=run,
        env=env,
        root=ROOT,
        require_terminal_boot=require_terminal_boot,
    )


def built_app_path(comparator: str) -> Path:
    scheme, _ = APPS[comparator]
    return (
        DERIVED_DATA
        / "Build/Products/Release-iphonesimulator"
        / f"{scheme}.app"
    )


def install_existing_apps(
    env: dict[str, str], udid: str, selected: list[str]
) -> None:
    for comparator in selected:
        app = built_app_path(comparator)
        if not app.is_dir():
            raise RuntimeError(
                f"missing prebuilt simulator app for {comparator}: {app.relative_to(ROOT)}"
            )
        _, bundle = APPS[comparator]
        run(
            ["xcrun", "simctl", "terminate", udid, bundle],
            env=env,
            timeout=30,
            check=False,
        )
        try:
            run(
                ["xcrun", "simctl", "install", udid, str(app)],
                env=env,
                timeout=120,
            )
        except subprocess.TimeoutExpired:
            recover_dedicated_simulator_user_services(
                udid=udid,
                root=ROOT,
                reason=f"prebuilt install timeout: {comparator}",
            )
            raise
        print(f"Installed prebuilt simulator app: {comparator}", flush=True)


def build_apps(env: dict[str, str], selected: list[str]) -> None:
    DERIVED_DATA.mkdir(parents=True, exist_ok=True)
    for comparator in selected:
        scheme, _ = APPS[comparator]
        print(f"Building simulator app: {comparator}", flush=True)
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
                "generic/platform=iOS Simulator",
                "-derivedDataPath",
                str(DERIVED_DATA),
                "CODE_SIGNING_ALLOWED=NO",
                "build",
            ],
            env=env,
            timeout=900,
        )
        if "** BUILD SUCCEEDED **" not in result.stdout:
            raise RuntimeError(f"{comparator} simulator build did not report success")
        print(f"Built simulator app: {comparator}", flush=True)


def specifications(
    selected: list[str],
    workloads: list[str],
) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    for comparator in selected:
        for workload in workloads:
            items.append(
                {
                    "comparator": comparator,
                    "workload": workload,
                    "cache": "cold",
                    "scale": 0.1 if workload == "W1-SCROLL-V1" else 1.0,
                }
            )
            if workload == "W2-HERO-V1":
                for cache in ["warm-disk", "warm-memory"]:
                    items.append(
                        {
                            "comparator": comparator,
                            "workload": workload,
                            "cache": cache,
                            "scale": 1.0,
                        }
                    )
    return items


def validate(
    data: dict[str, Any], spec: dict[str, Any], identity: dict[str, Any],
    plan_digest: str, claim_family_digest: str,
) -> None:
    if data.get("schemaVersion") != 3: raise RuntimeError("unexpected result schema")
    if data.get("planID") != "FOVEA-P0B-COMP-V1": raise RuntimeError("unexpected result plan")
    if data.get("harnessIdentity") != identity: raise RuntimeError("harness identity mismatch")
    if data.get("experimentPlanDigest") != plan_digest: raise RuntimeError("experiment plan digest mismatch")
    if data.get("claimFamilyDigest") != claim_family_digest: raise RuntimeError("claim-family digest mismatch")
    if data.get("executionEnvironment") != "simulator": raise RuntimeError("simulator result environment mismatch")
    environment_record = data.get("environment", {})
    drift = {
        key: {"expected": value, "actual": environment_record.get(key)}
        for key, value in SIMULATOR_IDENTITY.items()
        if environment_record.get(key) != value
    }
    if drift: raise RuntimeError(f"simulator environment identity mismatch: {drift}")
    if data.get("comparator",{}).get("name") != spec["comparator"]: raise RuntimeError("comparator mismatch")
    if data.get("workloadID") != spec["workload"] or data.get("cacheState") != spec["cache"]: raise RuntimeError("run identity mismatch")
    if data.get("provisional") is not True: raise RuntimeError("simulator result must be provisional")
    thermal = data.get("thermal")
    if not isinstance(thermal, dict): raise RuntimeError("thermal evidence is missing")
    if thermal.get("stateAtStart") not in {"nominal", "fair", "serious", "critical", "unknown"}:
        raise RuntimeError("invalid thermal start state")
    if thermal.get("stateAtEnd") not in {"nominal", "fair", "serious", "critical", "unknown"}:
        raise RuntimeError("invalid thermal end state")
    if not isinstance(thermal.get("remainedNominal"), bool):
        raise RuntimeError("invalid thermal stability flag")
    strings: list[str] = []
    def collect(value: Any) -> None:
        if isinstance(value, str):
            strings.append(value)
        elif isinstance(value, dict):
            for child in value.values(): collect(child)
        elif isinstance(value, list):
            for child in value: collect(child)
    collect(data)
    if any(token in value for value in strings for token in ["http://", "https://", "Bearer "]):
        raise RuntimeError("result leaks URL or credentials")


def result_name(spec: dict[str, Any]) -> str:
    return (
        f"{spec['comparator'].lower()}-{spec['workload'].lower()}-"
        f"{spec['cache']}-000.json"
    )


def artifact_path(spec: dict[str, Any]) -> Path:
    return (
        ARTIFACT_ROOT / "runs" / spec["comparator"] / spec["workload"]
        / spec["cache"] / result_name(spec)
    )


def write_report(
    selected: list[str], paths: list[Path], identity: dict[str, Any],
    plan_digest: str, claim_family_digest: str,
) -> dict[str, Any]:
    records = [json.loads(path.read_text()) for path in paths]
    failed = [
        {
            "comparator": record["comparator"]["name"],
            "workload": record["workloadID"],
            "check": check["identifier"],
            "value": check["value"],
        }
        for record in records
        for check in record["checks"]
        if not check["passed"]
    ]
    fovea_failures = [item for item in failed if item["comparator"] == "Fovea"]
    comparator_failures = [item for item in failed if item["comparator"] != "Fovea"]
    observed_workloads = sorted({record["workloadID"] for record in records})
    report = {
        "schemaVersion": 3,
        "mode": "simulator-calibration",
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "planID": "FOVEA-P0B-COMP-V1",
        "sourceIdentity": identity,
        "executionEnvironment": "simulator",
        "experimentPlanDigest": plan_digest,
        "claimFamilyDigest": claim_family_digest,
        "simulatorIdentity": SIMULATOR_IDENTITY,
        "deviceProfileID": SIMULATOR_IDENTITY["deviceProfileID"],
        "provisional": True,
        "releaseClaimPermitted": False,
        "selectedComparators": selected,
        "aTierHeadlessMatrix": A_TIER_HEADLESS,
        "aTierHeadlessComplete": (
            selected == A_TIER_HEADLESS
            and observed_workloads == ["W1-SCROLL-V1", "W2-HERO-V1", "W3-AUTH-V1"]
            and len(records) == 30
        ),
        "observedWorkloads": observed_workloads,
        "bTierRetained": B_TIER_RETAINED,
        "bTierIncluded": any(name in selected for name in B_TIER_RETAINED),
        "asyncImageIndependentSurface": "Benchmarks/AsyncImageLab/experiment-plan.json",
        "runCount": len(records),
        "foveaFailures": fovea_failures,
        "comparatorContractFailures": comparator_failures,
        "status": "completed" if not fovea_failures else "fovea-failed",
        "physicalDeviceEvidence": False,
        "physicalDeviceBlocker": "missing-valid-development-provisioning-profile",
        "runArtifacts": [str(path.relative_to(ROOT)) for path in paths],
    }
    ARTIFACT_ROOT.mkdir(parents=True, exist_ok=True)
    if selected == A_TIER_HEADLESS:
        suffix = "a-tier-headless"
    elif selected == A_TIER_HEADLESS + B_TIER_RETAINED:
        suffix = "a-plus-b-headless"
    else:
        suffix = "-".join(name.lower().replace(" ", "-") for name in selected)
    report_path = ARTIFACT_ROOT / f"calibration-report-{suffix}.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    if selected == A_TIER_HEADLESS:
        (ARTIFACT_ROOT / "calibration-report.json").write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n"
        )
    print(
        f"Simulator calibration {report['status']}: runs={len(records)} "
        f"foveaFailures={len(fovea_failures)} comparatorFailures={len(comparator_failures)}"
    )
    print(f"Artifact: {report_path.relative_to(ROOT)}")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run the A-tier headless iOS simulator calibration matrix; B-tier is opt-in."
    )
    parser.add_argument("--comparator", action="append", choices=list(APPS))
    parser.add_argument(
        "--workload",
        action="append",
        choices=["W1-SCROLL-V1", "W2-HERO-V1", "W3-AUTH-V1", "W4-PROGRESSIVE-JPEG-V1"],
        help="Limit calibration to selected workloads; W4 uses the constrained network profile.",
    )
    parser.add_argument(
        "--build-only",
        action="store_true",
        help="Prepare resources and build selected apps without installing or measuring.",
    )
    parser.add_argument(
        "--initialize-simulator-only",
        action="store_true",
        help="Resolve the exact runtime build and complete dedicated simulator boot only.",
    )
    parser.add_argument(
        "--install-only",
        action="store_true",
        help="Install selected prebuilt Release apps without rebuilding or measuring.",
    )
    parser.add_argument(
        "--diagnostic",
        action="store_true",
        help="Skip the quiescent-host gate for rapid directional runs; never claim-eligible.",
    )
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--skip-prepare", action="store_true")
    parser.add_argument("--aggregate-only", action="store_true")
    parser.add_argument(
        "--include-b-tier",
        action="store_true",
        help="Append AlamofireImage as separately classified B-tier evidence.",
    )
    args = parser.parse_args()
    operation_modes = sum(
        bool(value)
        for value in (
            args.build_only,
            args.install_only,
            args.initialize_simulator_only,
            args.aggregate_only,
        )
    )
    if operation_modes > 1:
        parser.error(
            "--build-only, --install-only, --initialize-simulator-only and "
            "--aggregate-only are mutually exclusive"
        )
    if args.build_only and args.skip_build:
        parser.error("--build-only cannot be combined with --skip-build")
    if args.install_only and (args.skip_build or args.skip_prepare):
        parser.error("--install-only already skips build and preparation")
    if (
        not args.build_only
        and not args.install_only
        and not args.initialize_simulator_only
        and not args.aggregate_only
        and not (args.skip_build and args.skip_prepare)
    ):
        parser.error(
            "measurement runs require --skip-build --skip-prepare; use --build-only first"
        )
    if args.comparator:
        selected = args.comparator
    else:
        selected = A_TIER_HEADLESS + (B_TIER_RETAINED if args.include_b_tier else [])
    try:
        env=environment()
        if args.initialize_simulator_only:
            udid = simulator(env)
            print(f"Dedicated simulator initialized: device={udid} measurements=0")
            return 0
        if args.install_only:
            udid = simulator(env)
            install_existing_apps(env, udid, selected)
            print(
                "Prebuilt simulator apps installed: "
                f"comparators={len(selected)} device={udid} measurements=0"
            )
            return 0
        if not args.skip_prepare:
            run(["python3","scripts/capture-comparative-dataset.py","--delay","3"],env=env,timeout=300)
            run(["python3","scripts/prepare-comparative-app-resources.py"],env=env,timeout=120)
            run(["xcodegen","generate","--spec",str(ROOT/"Benchmarks/ComparativeLab/Apps/project.yml")],env=env,timeout=120)
        identity=git_identity(env)
        plan_digest=canonical_digest(ROOT/"Benchmarks/ComparativeLab/experiment-plan.json")
        claim_family_digest=canonical_digest(ROOT/"Benchmarks/statistical-claim-families.json")
        workloads = args.workload or ["W1-SCROLL-V1", "W2-HERO-V1", "W3-AUTH-V1"]
        specs = specifications(selected, workloads)
        if args.aggregate_only:
            paths=[]
            for spec in specs:
                path=artifact_path(spec)
                if not path.is_file():
                    raise RuntimeError(f"missing current simulator artifact: {path.relative_to(ROOT)}")
                data=json.loads(path.read_text())
                validate(data,spec,identity,plan_digest,claim_family_digest)
                paths.append(path)
            report=write_report(selected,paths,identity,plan_digest,claim_family_digest)
            return 0 if report["status"] == "completed" else 1
        if args.build_only:
            build_apps(env, selected)
            print(
                "Simulator apps built: "
                f"comparators={len(selected)} installations=0 measurements=0"
            )
            return 0
        udid=simulator(env)
        if not args.skip_build:
            build_apps(env, selected)
            install_existing_apps(env, udid, selected)
        if args.diagnostic:
            print(
                "Diagnostic mode: quiescent-host gate skipped; artifacts are directional only.",
                flush=True,
            )
        else:
            assert_measurement_host_quiet(root=ROOT)
        paths=[]
        for index,spec in enumerate(specs,1):
            comparator=spec["comparator"]
            _,bundle=APPS[comparator]
            name=result_name(spec)
            child=env.copy()
            child.update({
                "SIMCTL_CHILD_FOVEA_BENCHMARK_COMMIT":identity["commit"],
                "SIMCTL_CHILD_FOVEA_BENCHMARK_TREE_DIGEST":identity["sourceTreeDigest"],
                "SIMCTL_CHILD_FOVEA_BENCHMARK_DIRTY":"1" if identity["includesWorkingTreeChanges"] else "0",
                "SIMCTL_CHILD_FOVEA_EXPERIMENT_PLAN_ID":"FOVEA-P0B-COMP-V1",
                "SIMCTL_CHILD_FOVEA_EXPERIMENT_PLAN_DIGEST":plan_digest,
                "SIMCTL_CHILD_FOVEA_CLAIM_FAMILY_DIGEST":claim_family_digest,
                "SIMCTL_CHILD_FOVEA_SIMULATOR_PROFILE_ID":SIMULATOR_IDENTITY["deviceProfileID"],
                "SIMCTL_CHILD_FOVEA_SIMULATOR_OS_VERSION":SIMULATOR_IDENTITY["osVersion"],
                "SIMCTL_CHILD_FOVEA_SIMULATOR_OS_BUILD":SIMULATOR_IDENTITY["osBuild"],
                "SIMCTL_CHILD_FOVEA_SIMULATOR_OS_CHANNEL":SIMULATOR_IDENTITY["osChannel"],
            })
            print(f"Simulator run {index}/{len(specs)}: {comparator} {spec['workload']} {spec['cache']}",flush=True)
            container=Path(run(["xcrun","simctl","get_app_container",udid,bundle,"data"],env=env,timeout=60).stdout.strip())
            source=container/"Documents"/name
            source.unlink(missing_ok=True)
            run([
                "xcrun","simctl","launch","--terminate-running-process",udid,bundle,
                "--workload",spec["workload"],"--cache-state",spec["cache"],"--network-profile",
                "NET-CONSTRAINED-V1" if spec["workload"] == "W4-PROGRESSIVE-JPEG-V1" else "NET-LOCAL-V1",
                "--run-index","0","--time-scale",str(spec["scale"]),"--output",name,
            ],env=child,timeout=60)
            deadline=time.monotonic()+240
            while time.monotonic()<deadline and not source.is_file():
                time.sleep(0.5)
            if not source.is_file():
                raise RuntimeError(f"missing simulator result after timeout: {name}")
            data=json.loads(source.read_text()); validate(data,spec,identity,plan_digest,claim_family_digest)
            dest=artifact_path(spec)
            dest.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(source,dest); paths.append(dest)
        report=write_report(selected,paths,identity,plan_digest,claim_family_digest)
        return 0 if report["status"] == "completed" else 1
    except Exception as error:
        print(f"Comparative simulator lab failed: {error}",file=sys.stderr)
        return 1

if __name__=="__main__": raise SystemExit(main())
