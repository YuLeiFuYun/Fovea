#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from comparative_simulator_support import (
    SIMULATOR_RUNTIME_BUILD,
    SIMULATOR_RUNTIME_VERSION,
    ensure_dedicated_simulator,
    recover_dedicated_simulator_user_services,
)

ROOT = Path(__file__).resolve().parents[1]
_VALIDATOR_PATH = ROOT / "scripts/validate-w5-animated-timing.py"
_VALIDATOR_SPEC = importlib.util.spec_from_file_location("fovea_validate_w5_animated_timing", _VALIDATOR_PATH)
if _VALIDATOR_SPEC is None or _VALIDATOR_SPEC.loader is None:
    raise RuntimeError("failed to load W5 animated timing validator")
_VALIDATOR_MODULE = importlib.util.module_from_spec(_VALIDATOR_SPEC)
_VALIDATOR_SPEC.loader.exec_module(_VALIDATOR_MODULE)
validate_artifact = _VALIDATOR_MODULE.validate_artifact
PROJECT = ROOT / "Benchmarks/ComparativeLab/Apps/FoveaComparativeApps.xcodeproj"
PLAN = ROOT / "Benchmarks/ComparativeLab/animated-player-mechanism-plan.json"
CLAIMS = ROOT / "Benchmarks/statistical-claim-families.json"
ARTIFACT_ROOT = ROOT / ".artifacts/w5-player-timing/simulator"
FIXTURE_MANIFEST = ROOT / "Benchmarks/ComparativeLab/Fixtures/animated-player-fixtures.json"
APPS = {
    "APNGKit": ("APNGKitComparatorBench", "dev.fovea.comparative.apngkit"),
    "AnimatedImage": ("AnimatedImageComparatorBench", "dev.fovea.comparative.animatedimage"),
    "FLAnimatedImage": ("FLAnimatedImageComparatorBench", "dev.fovea.comparative.flanimatedimage"),
    "Gifu": ("GifuComparatorBench", "dev.fovea.comparative.gifu"),
    "Fovea": ("FoveaComparatorBench", "dev.fovea.comparative.fovea"),
    "Kingfisher": ("KingfisherComparatorBench", "dev.fovea.comparative.kingfisher"),
    "PINRemoteImage": ("PINRemoteImageComparatorBench", "dev.fovea.comparative.pinremoteimage"),
    "SDWebImage": ("SDWebImageComparatorBench", "dev.fovea.comparative.sdwebimage"),
}
SIMULATOR_PROFILE_ID = "ios26-4-simulator-calibration-v1"
COMPARATOR_ISOLATION_MODE = "shutdown-boot-between-comparators-v1"
EXPECTED_SEMANTIC_REJECTIONS = {
    ("AnimatedImage", "GIF-VARIABLE-DELAY-60"): "w5-native-timeline-semantic-mismatch",
}
EXPECTED_FRESH_SIMULATOR_INSTABILITIES = {
    ("FLAnimatedImage", "GIF-VARIABLE-DELAY-60"): (
        "w5-player-timing-timeout:count=0:progression=0",
        "w5-player-timing-timeout:count=1:progression=0",
    ),
}


def run(command: list[str], *, env: dict[str, str], timeout: int = 120, check: bool = True) -> subprocess.CompletedProcess[str]:
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
        raise error
    result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    if check and result.returncode != 0:
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(command[:8])}\n{stderr[-6000:]}")
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
    for relative in sorted(item for item in untracked if item):
        path = ROOT / relative
        if path.is_file() and not path.is_symlink():
            digest.update(relative.encode() + b"\0" + path.read_bytes() + b"\0")
    return {"commit": head, "sourceTreeDigest": digest.hexdigest(), "includesWorkingTreeChanges": dirty}


def canonical_digest(path: Path) -> str:
    value = json.loads(path.read_text())
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest()


def app_bundle_identity(app: Path, *, scheme: str, expected_bundle_id: str) -> dict[str, Any]:
    if not app.is_dir():
        raise RuntimeError(f"app bundle is missing: {app}")
    info_path = app / "Info.plist"
    if not info_path.is_file():
        raise RuntimeError(f"app bundle Info.plist is missing: {app}")
    info = plistlib.loads(info_path.read_bytes())
    bundle_id = str(info.get("CFBundleIdentifier") or "")
    executable_name = str(info.get("CFBundleExecutable") or "")
    if bundle_id != expected_bundle_id:
        raise RuntimeError(
            f"app bundle identifier mismatch for {scheme}: expected {expected_bundle_id} got {bundle_id}"
        )
    if not executable_name:
        raise RuntimeError(f"app bundle executable is missing from Info.plist: {scheme}")
    executable = app / executable_name
    if not executable.is_file():
        raise RuntimeError(f"app bundle executable is missing: {executable}")

    tree = hashlib.sha256()
    file_count = 0
    symlink_count = 0
    total_file_bytes = 0
    for path in sorted(app.rglob("*"), key=lambda item: item.relative_to(app).as_posix()):
        relative = path.relative_to(app).as_posix()
        if path.is_symlink():
            target = os.readlink(path)
            tree.update(b"L\0" + relative.encode() + b"\0" + target.encode() + b"\0")
            symlink_count += 1
        elif path.is_file():
            data = path.read_bytes()
            digest = hashlib.sha256(data).hexdigest()
            tree.update(
                b"F\0"
                + relative.encode()
                + b"\0"
                + str(len(data)).encode()
                + b"\0"
                + digest.encode()
                + b"\0"
            )
            file_count += 1
            total_file_bytes += len(data)
    executable_data = executable.read_bytes()
    return {
        "scheme": scheme,
        "bundleIdentifier": bundle_id,
        "executable": executable_name,
        "executableByteCount": len(executable_data),
        "executableSHA256": hashlib.sha256(executable_data).hexdigest(),
        "bundleFileCount": file_count,
        "bundleSymlinkCount": symlink_count,
        "bundleTotalFileBytes": total_file_bytes,
        "bundleTreeDigestAlgorithm": "relative-path-size-file-sha256-v1",
        "bundleTreeDigest": tree.hexdigest(),
    }


def newest_prebuilt_app(scheme: str, configuration: str) -> Path:
    pattern = Path.home() / "Library/Developer/Xcode/DerivedData"
    candidates = list(pattern.glob(f"FoveaComparativeApps-*/Build/Products/{configuration}-iphonesimulator/{scheme}.app"))
    candidates = [item for item in candidates if item.is_dir()]
    if not candidates:
        raise RuntimeError(f"no prebuilt {configuration} app found for {scheme}")
    return max(candidates, key=lambda item: item.stat().st_mtime_ns)


def build_app(env: dict[str, str], scheme: str, configuration: str) -> Path:
    run([sys.executable, str(ROOT / "scripts/prepare-comparative-app-resources.py")], env=env, timeout=60)
    run(["xcodegen", "generate", "--spec", str(ROOT / "Benchmarks/ComparativeLab/Apps/project.yml")], env=env, timeout=60)
    run(
        [
            "xcodebuild", "-quiet", "-project", str(PROJECT), "-scheme", scheme,
            "-configuration", configuration, "-sdk", "iphonesimulator", "ARCHS=arm64",
            "ONLY_ACTIVE_ARCH=YES", "CODE_SIGNING_ALLOWED=NO", "build",
        ],
        env=env,
        timeout=900,
    )
    return newest_prebuilt_app(scheme, configuration)


def wait_for_result(result: Path, failure: Path, *, timeout: float = 20.0) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if failure.is_file():
            return "failure"
        if result.is_file():
            return "result"
        time.sleep(0.25)
    raise RuntimeError(f"timed out waiting for {result.name}")


def benchmark_result_paths(container: Path, name: str) -> tuple[Path, Path]:
    source = container / "Documents" / name
    return source, source.with_name(name + ".failure")


def installed_app_container(
    *, udid: str, bundle: str, env: dict[str, str]
) -> Path:
    return Path(
        run(
            ["xcrun", "simctl", "get_app_container", udid, bundle, "data"],
            env=env,
            timeout=30,
        ).stdout.strip()
    )


def run_one(
    *,
    comparator: str,
    run_index: int,
    app: Path,
    udid: str,
    env: dict[str, str],
    output_directory: Path,
    fixture_id: str,
) -> dict[str, Any]:
    scheme, bundle = APPS[comparator]
    run(["xcrun", "simctl", "terminate", udid, bundle], env=env, check=False, timeout=30)
    run(["xcrun", "simctl", "uninstall", udid, bundle], env=env, check=False, timeout=30)
    run(["xcrun", "simctl", "install", udid, str(app)], env=env, timeout=120)
    fixture_slug = fixture_id.lower().replace("-", "_")
    name = f"{scheme}-w5-{fixture_slug}-{run_index:03d}.json"
    container = installed_app_container(udid=udid, bundle=bundle, env=env)
    source, failure = benchmark_result_paths(container, name)
    source.unlink(missing_ok=True)
    failure.unlink(missing_ok=True)
    launch_command = [
        "xcrun", "simctl", "launch", "--terminate-running-process", udid, bundle,
        "--workload", "W5-ANIMATED-MEDIA-V1", "--cache-state", "cold",
        "--network-profile", "NET-LOCAL-V1", "--run-index", str(run_index),
        "--time-scale", "1", "--w5-fixture", fixture_id, "--output", name,
    ]
    try:
        run(launch_command, env=env, timeout=15)
    except subprocess.TimeoutExpired:
        # simctl launch can occasionally block after the app was successfully admitted.
        # The result/failure file is the execution source of truth, not launch IPC return.
        try:
            wait_for_result(source, failure, timeout=12)
        except RuntimeError:
            recover_dedicated_simulator_user_services(
                udid=udid,
                root=ROOT,
                reason=f"W5 launch IPC timeout before result: {comparator}",
            )
            ready_udid = ensure_dedicated_simulator(
                run_command=run, env=env, root=ROOT, require_terminal_boot=False
            )
            if ready_udid != udid:
                raise RuntimeError("dedicated simulator identity changed during W5 recovery")
            run(["xcrun", "simctl", "install", udid, str(app)], env=env, timeout=120)
            # uninstall/install may assign a new Simulator data-container UUID.
            # Always resolve result paths again after reinstall; waiting on the old
            # container can falsely report a benchmark timeout even when the app
            # completed and wrote a valid artifact.
            container = installed_app_container(udid=udid, bundle=bundle, env=env)
            source, failure = benchmark_result_paths(container, name)
            source.unlink(missing_ok=True)
            failure.unlink(missing_ok=True)
            run(launch_command, env=env, timeout=30)
    outcome = wait_for_result(source, failure)
    if outcome == "failure":
        failure_text = failure.read_text(errors="replace").strip()
        destination = (
            output_directory
            / f"{comparator.lower()}-{fixture_slug}-{run_index:03d}.failure.txt"
        )
        shutil.copy2(failure, destination)
        expected_rejection = EXPECTED_SEMANTIC_REJECTIONS.get((comparator, fixture_id))
        if expected_rejection is not None and expected_rejection in failure_text:
            return {
                "comparator": comparator,
                "fixtureID": fixture_id,
                "status": "not-comparable-semantic-timeline",
                "reason": expected_rejection,
                "provisional": True,
                "claimBoundary": "semantic-gap-no-ranking",
                "failureEvidence": str(destination.relative_to(ROOT)),
            }
        expected_instabilities = EXPECTED_FRESH_SIMULATOR_INSTABILITIES.get(
            (comparator, fixture_id), ()
        )
        matching_instability = next(
            (value for value in expected_instabilities if value in failure_text), None
        )
        if matching_instability is not None:
            return {
                "comparator": comparator,
                "fixtureID": fixture_id,
                "status": "not-comparable-fresh-simulator-instability",
                "reason": matching_instability,
                "observedFailure": failure_text,
                "provisional": True,
                "claimBoundary": "fresh-simulator-player-stability-gap-no-ranking",
                "failureEvidence": str(destination.relative_to(ROOT)),
            }
        raise RuntimeError(
            f"benchmark failed: {failure_text}; failureEvidence={destination.relative_to(ROOT)}"
        )
    destination = output_directory / f"{comparator.lower()}-{fixture_slug}-{run_index:03d}.json"
    shutil.copy2(source, destination)
    summary = validate_artifact(
        destination,
        expected_comparator=comparator,
        expected_fixture_id=fixture_id,
    )
    summary["status"] = "calibrated"
    return summary


def isolate_comparator_simulator(
    *, udid: str, env: dict[str, str]
) -> str:
    run(
        ["xcrun", "simctl", "shutdown", udid],
        env=env,
        timeout=60,
        check=False,
    )
    ready_udid = ensure_dedicated_simulator(
        run_command=run, env=env, root=ROOT, require_terminal_boot=False
    )
    if ready_udid != udid:
        raise RuntimeError("dedicated simulator identity changed during comparator isolation")
    return ready_udid


def main() -> int:
    parser = argparse.ArgumentParser(description="Run W5 animated-player structural simulator calibration. Results are provisional and non-ranking.")
    parser.add_argument("--comparators", nargs="+", choices=sorted(APPS), default=list(APPS))
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Debug")
    parser.add_argument("--fixture-id", default="GIF-VARIABLE-DELAY-60")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--run-index-base", type=int, default=0)
    args = parser.parse_args()
    fixture_manifest = json.loads(FIXTURE_MANIFEST.read_text())
    fixture_ids = {item.get("id") for item in fixture_manifest.get("fixtures", [])}
    if args.fixture_id not in fixture_ids:
        raise RuntimeError(f"unknown W5 fixture: {args.fixture_id}")

    env = environment()
    plan = json.loads(PLAN.read_text())
    plan_id = plan.get("planID")
    if plan_id != "FOVEA-W5-ANIMATED-PLAYER-MECHANISMS-V1":
        raise RuntimeError("W5 animated player planID is missing or changed")
    identity = git_identity(env)
    injected = {
        "SIMCTL_CHILD_FOVEA_BENCHMARK_COMMIT": identity["commit"],
        "SIMCTL_CHILD_FOVEA_BENCHMARK_TREE_DIGEST": identity["sourceTreeDigest"],
        "SIMCTL_CHILD_FOVEA_BENCHMARK_DIRTY": "1" if identity["includesWorkingTreeChanges"] else "0",
        "SIMCTL_CHILD_FOVEA_EXPERIMENT_PLAN_ID": plan_id,
        "SIMCTL_CHILD_FOVEA_EXPERIMENT_PLAN_DIGEST": canonical_digest(PLAN),
        "SIMCTL_CHILD_FOVEA_CLAIM_FAMILY_DIGEST": canonical_digest(CLAIMS),
        "SIMCTL_CHILD_FOVEA_SIMULATOR_PROFILE_ID": SIMULATOR_PROFILE_ID,
        "SIMCTL_CHILD_FOVEA_SIMULATOR_OS_VERSION": SIMULATOR_RUNTIME_VERSION,
        "SIMCTL_CHILD_FOVEA_SIMULATOR_OS_BUILD": SIMULATOR_RUNTIME_BUILD,
        "SIMCTL_CHILD_FOVEA_SIMULATOR_OS_CHANNEL": "stable",
    }
    env.update(injected)
    udid = ensure_dedicated_simulator(run_command=run, env=env, root=ROOT, require_terminal_boot=False)
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output_directory = ARTIFACT_ROOT / timestamp
    output_directory.mkdir(parents=True, exist_ok=True)

    summaries: list[dict[str, Any]] = []
    for offset, comparator in enumerate(args.comparators):
        if offset > 0:
            isolate_comparator_simulator(udid=udid, env=env)
        scheme, bundle = APPS[comparator]
        app = newest_prebuilt_app(scheme, args.configuration) if args.skip_build else build_app(env, scheme, args.configuration)
        bundle_identity = app_bundle_identity(
            app, scheme=scheme, expected_bundle_id=bundle
        )
        bundle_identity["selectionMode"] = (
            "prebuilt-reused" if args.skip_build else "built-current-run"
        )
        summary = run_one(
            comparator=comparator,
            run_index=args.run_index_base + offset,
            app=app,
            udid=udid,
            env=env,
            output_directory=output_directory,
            fixture_id=args.fixture_id,
        )
        summary["appBundleIdentity"] = bundle_identity
        summary["simulatorIsolationMode"] = COMPARATOR_ISOLATION_MODE
        summaries.append(summary)
        if summary["status"] == "calibrated":
            print(
                f"W5 structural calibration passed: {comparator} "
                f"observations={summary['observationCount']} transitions={summary['transitionCount']}",
                flush=True,
            )
        else:
            print(
                f"W5 semantic boundary preserved: {comparator} "
                f"fixture={summary['fixtureID']} status={summary['status']}",
                flush=True,
            )

    manifest_status = (
        "passed-structural-simulator-calibration-with-explicit-not-comparable"
        if any(item["status"].startswith("not-comparable") for item in summaries)
        else "passed-structural-simulator-calibration-no-ranking"
    )
    manifest = {
        "schemaVersion": 1,
        "capturedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "status": manifest_status,
        "planID": plan_id,
        "planDigest": canonical_digest(PLAN),
        "fixtureID": args.fixture_id,
        "claimFamilyDigest": canonical_digest(CLAIMS),
        "simulator": {
            "deviceUDID": udid,
            "profileID": SIMULATOR_PROFILE_ID,
            "osVersion": SIMULATOR_RUNTIME_VERSION,
            "osBuild": SIMULATOR_RUNTIME_BUILD,
            "osChannel": "stable",
        },
        "sourceIdentity": identity,
        "comparatorIsolationMode": COMPARATOR_ISOLATION_MODE,
        "results": summaries,
        "forbiddenInterpretation": "Simulator timing numbers are directional structural calibration only and must not be used to rank players or activate a performance claim.",
    }
    manifest_path = output_directory / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"W5 animated simulator structural calibration: {manifest_path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
