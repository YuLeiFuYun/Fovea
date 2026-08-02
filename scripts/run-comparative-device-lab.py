#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
PROJECT_DIR = ROOT / "Benchmarks/ComparativeLab/Apps"
PROJECT = PROJECT_DIR / "FoveaComparativeApps.xcodeproj"
ARTIFACT_ROOT = ROOT / ".artifacts/comparative-device-lab"
DERIVED_DATA = ARTIFACT_ROOT / "DerivedData"
DEVICE_PROFILE = ROOT / ".artifacts/phase0b/device-profile.json"
RESULT_ROOT = ARTIFACT_ROOT / "runs"
SHA40 = re.compile(r"^[0-9a-f]{40}$")
SHA64 = re.compile(r"^[0-9a-f]{64}$")

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



def run(
    command: list[str],
    *,
    env: dict[str, str] | None = None,
    timeout: int = 600,
    capture: bool = True,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        timeout=timeout,
        check=False,
    )
    if check and result.returncode != 0:
        if result.stdout:
            print(result.stdout[-12000:], file=sys.stderr)
        if result.stderr:
            print(result.stderr[-12000:], file=sys.stderr)
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(command[:5])}")
    return result


def xcode_environment() -> dict[str, str]:
    env = os.environ.copy()
    if not env.get("DEVELOPER_DIR"):
        selected = run([str(ROOT / "scripts/select-xcode.sh")]).stdout.strip()
        env["DEVELOPER_DIR"] = selected
    return env


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_identity() -> dict[str, Any]:
    head = run(["git", "rev-parse", "HEAD"]).stdout.strip()
    if SHA40.fullmatch(head) is None:
        raise RuntimeError("invalid Git HEAD")
    status = run(["git", "status", "--porcelain=v1", "-z"]).stdout
    dirty = bool(status)
    digest = hashlib.sha256()
    digest.update(b"fovea-worktree-v1\0")
    digest.update(head.encode())
    diff = subprocess.run(
        ["git", "diff", "--binary", "HEAD"], cwd=ROOT, stdout=subprocess.PIPE, check=True
    ).stdout
    digest.update(diff)
    untracked = run(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"]
    ).stdout.split("\0")
    for relative in sorted(value for value in untracked if value):
        path = ROOT / relative
        if not path.is_file() or path.is_symlink():
            continue
        digest.update(relative.encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return {
        "commit": head,
        "sourceTreeDigest": digest.hexdigest(),
        "includesWorkingTreeChanges": dirty,
    }


def canonical_digest(path: Path) -> str:
    value = json.loads(path.read_text())
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def connected_device(env: dict[str, str]) -> tuple[str, list[str]]:
    with tempfile.TemporaryDirectory(prefix="fovea-device-list-") as temp:
        output = Path(temp) / "devices.json"
        run(
            ["xcrun", "devicectl", "list", "devices", "--json-output", str(output)],
            env=env,
            timeout=90,
        )
        data = json.loads(output.read_text())
    candidates: list[dict[str, Any]] = []
    for device in data.get("result", {}).get("devices", []):
        hardware = device.get("hardwareProperties", {})
        properties = device.get("deviceProperties", {})
        if hardware.get("reality") != "physical":
            continue
        if hardware.get("productType") != "iPhone17,5":
            continue
        if properties.get("bootState") not in {"booted", "connected"} and not device.get(
            "connectionProperties", {}
        ).get("tunnelState") in {"connected", "active"}:
            # devicectl versions expose connected state in different fields. Presence in the
            # connected physical list is accepted when DDI services are available.
            if not properties.get("ddiServicesAvailable", False):
                continue
        candidates.append(device)
    if len(candidates) != 1:
        raise RuntimeError(f"expected exactly one connected physical iPhone 16e, found {len(candidates)}")
    device = candidates[0]
    identifier = device.get("identifier")
    if not isinstance(identifier, str) or not identifier:
        raise RuntimeError("connected device identifier unavailable")
    private_values = [identifier]
    for value in [
        device.get("deviceProperties", {}).get("name"),
        device.get("connectionProperties", {}).get("potentialHostnames", [None])[0]
        if isinstance(device.get("connectionProperties", {}).get("potentialHostnames"), list)
        else None,
        device.get("hardwareProperties", {}).get("udid"),
    ]:
        if isinstance(value, str) and value:
            private_values.append(value)
    return identifier, private_values


def prepare_project(env: dict[str, str]) -> None:
    run(["python3", "scripts/capture-comparative-dataset.py", "--delay", "3"], env=env, timeout=900)
    run(["python3", "scripts/prepare-comparative-app-resources.py"], env=env, timeout=120)
    run(["xcodegen", "generate", "--spec", str(PROJECT_DIR / "project.yml")], env=env, timeout=120, capture=True)


def build_apps(
    env: dict[str, str],
    device_id: str,
    configuration: str,
    selected: list[str],
) -> dict[str, Path]:
    DERIVED_DATA.mkdir(parents=True, exist_ok=True)
    products: dict[str, Path] = {}
    for comparator in selected:
        scheme, _ = APPS[comparator]
        print(f"Building {comparator} device app", flush=True)
        result = run(
            [
                "xcodebuild",
                "-project",
                str(PROJECT),
                "-scheme",
                scheme,
                "-configuration",
                configuration,
                "-destination",
                f"platform=iOS,id={device_id}",
                "-derivedDataPath",
                str(DERIVED_DATA),
                "-allowProvisioningUpdates",
                "build",
            ],
            env=env,
            timeout=900,
        )
        if "** BUILD SUCCEEDED **" not in result.stdout:
            raise RuntimeError(f"{comparator} device build did not report success")
        app = DERIVED_DATA / "Build/Products" / f"{configuration}-iphoneos" / f"{scheme}.app"
        if not app.is_dir():
            raise RuntimeError(f"missing built app: {app}")
        products[comparator] = app
    return products


def install_apps(env: dict[str, str], device_id: str, products: dict[str, Path]) -> None:
    for comparator, app in products.items():
        print(f"Installing {comparator} device app", flush=True)
        run(
            ["xcrun", "devicectl", "device", "install", "app", "--device", device_id, str(app)],
            env=env,
            timeout=180,
        )


def calibration_runs(selected: list[str]) -> list[dict[str, Any]]:
    runs: list[dict[str, Any]] = []
    for comparator in selected:
        for workload in ["W1-SCROLL-V1", "W2-HERO-V1", "W3-AUTH-V1"]:
            runs.append(
                {
                    "comparator": comparator,
                    "workload": workload,
                    "cacheState": "cold",
                    "networkProfile": "NET-LOCAL-V1",
                    "runIndex": 0,
                    "timeScale": 0.1 if workload == "W1-SCROLL-V1" else 1.0,
                    "blockID": f"calibration-{comparator}-{workload}-cold",
                }
            )
        for cache_state in ["warm-disk", "warm-memory"]:
            runs.append(
                {
                    "comparator": comparator,
                    "workload": "W2-HERO-V1",
                    "cacheState": cache_state,
                    "networkProfile": "NET-LOCAL-V1",
                    "runIndex": 0,
                    "timeScale": 1.0,
                    "blockID": f"calibration-{comparator}-W2-HERO-V1-{cache_state}",
                }
            )
    return runs


def formal_runs() -> list[dict[str, Any]]:
    plan = json.loads((ROOT / "Benchmarks/ComparativeLab/experiment-plan.json").read_text())
    runs: list[dict[str, Any]] = []
    permutations = plan["execution"]["interleaving"]["block"]
    for workload in ["W1-SCROLL-V1", "W2-HERO-V1", "W3-AUTH-V1"]:
        for cache_state, repetitions in [
            ("cold", plan["execution"]["coldCacheRepetitions"]),
            ("warm-disk", plan["execution"]["warmStateRepetitions"]),
            ("warm-memory", plan["execution"]["warmStateRepetitions"]),
        ]:
            for index in range(repetitions):
                order = permutations[index % len(permutations)]
                for comparator in order:
                    runs.append(
                        {
                            "comparator": comparator,
                            "workload": workload,
                            "cacheState": cache_state,
                            "networkProfile": "NET-LOCAL-V1",
                            "runIndex": index,
                            "timeScale": 1.0,
                            "blockID": f"formal-{workload}-{cache_state}-{index:03d}",
                        }
                    )
    return runs


def run_one(
    env: dict[str, str],
    device_id: str,
    private_values: list[str],
    identity: dict[str, Any],
    plan_digest: str,
    claim_family_digest: str,
    specification: dict[str, Any],
) -> Path:
    comparator = specification["comparator"]
    _, bundle_id = APPS[comparator]
    safe = (
        f"{comparator.lower()}-{specification['workload'].lower()}-"
        f"{specification['cacheState']}-{specification['networkProfile'].lower()}-"
        f"{specification['runIndex']:03d}.json"
    ).replace("_", "-")
    environment = {
        "FOVEA_BENCHMARK_COMMIT": identity["commit"],
        "FOVEA_BENCHMARK_TREE_DIGEST": identity["sourceTreeDigest"],
        "FOVEA_BENCHMARK_DIRTY": "1" if identity["includesWorkingTreeChanges"] else "0",
        "FOVEA_EXPERIMENT_PLAN_ID": "FOVEA-P0B-COMP-V1",
        "FOVEA_EXPERIMENT_PLAN_DIGEST": plan_digest,
        "FOVEA_CLAIM_FAMILY_DIGEST": claim_family_digest,
    }
    print(
        f"Running {comparator} {specification['workload']} {specification['cacheState']} ",
        f"profile={specification['networkProfile']}",
        flush=True,
    )
    run(
        [
            "xcrun",
            "devicectl",
            "device",
            "process",
            "launch",
            "--device",
            device_id,
            "--console",
            "--terminate-existing",
            "--environment-variables",
            json.dumps(environment, separators=(",", ":")),
            bundle_id,
            "--workload",
            specification["workload"],
            "--cache-state",
            specification["cacheState"],
            "--network-profile",
            specification["networkProfile"],
            "--run-index",
            str(specification["runIndex"]),
            "--time-scale",
            str(specification["timeScale"]),
            "--output",
            safe,
        ],
        env=env,
        timeout=240,
    )
    destination = RESULT_ROOT / comparator / specification["workload"] / specification["cacheState"]
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / safe
    with tempfile.TemporaryDirectory(prefix="fovea-device-copy-") as temp:
        copied = Path(temp) / safe
        run(
            [
                "xcrun",
                "devicectl",
                "device",
                "copy",
                "from",
                "--device",
                device_id,
                "--domain-type",
                "appDataContainer",
                "--domain-identifier",
                bundle_id,
                "--source",
                f"Documents/{safe}",
                "--destination",
                str(copied),
            ],
            env=env,
            timeout=120,
        )
        if copied.is_dir():
            candidates = list(copied.rglob(safe))
            if len(candidates) != 1:
                raise RuntimeError(f"could not locate copied result {safe}")
            copied = candidates[0]
        data = json.loads(copied.read_text())
        validate_result(
            data, comparator, specification, private_values, identity,
            plan_digest, claim_family_digest,
        )
        shutil.copy2(copied, target)
    return target


def validate_result(
    data: dict[str, Any], comparator: str, specification: dict[str, Any], private_values: list[str],
    identity: dict[str, Any], plan_digest: str, claim_family_digest: str,
) -> None:
    if data.get("schemaVersion") != 3 or data.get("planID") != "FOVEA-P0B-COMP-V1":
        raise RuntimeError("result schema/plan mismatch")
    if data.get("harnessIdentity") != identity:
        raise RuntimeError("result harness identity mismatch")
    if data.get("experimentPlanDigest") != plan_digest:
        raise RuntimeError("result experiment plan digest mismatch")
    if data.get("claimFamilyDigest") != claim_family_digest:
        raise RuntimeError("result claim-family digest mismatch")
    if data.get("executionEnvironment") != "physical-device":
        raise RuntimeError("result execution environment mismatch")
    if data.get("comparator", {}).get("name") != comparator:
        raise RuntimeError("result comparator mismatch")
    if data.get("workloadID") != specification["workload"]:
        raise RuntimeError("result workload mismatch")
    if data.get("cacheState") != specification["cacheState"]:
        raise RuntimeError("result cache-state mismatch")
    if data.get("environment", {}).get("deviceProfileID") != "iphone-16e-ios27-beta-primary-v1":
        raise RuntimeError("result device profile mismatch")
    if not data.get("provisional", False):
        raise RuntimeError("iOS beta result must remain provisional")
    thermal = data.get("thermal")
    if not isinstance(thermal, dict):
        raise RuntimeError("result thermal evidence is missing")
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
            for child in value.values():
                collect(child)
        elif isinstance(value, list):
            for child in value:
                collect(child)
    collect(data)
    forbidden = ["http://", "https://", "Bearer "] + private_values
    if any(token and token in value for value in strings for token in forbidden):
        raise RuntimeError("result contains private or credential-bearing material")
    checks = data.get("checks")
    if not isinstance(checks, list) or not checks:
        raise RuntimeError("result contains no checks")


def grouped_blocks(specifications: list[dict[str, Any]]) -> list[list[dict[str, Any]]]:
    blocks: list[list[dict[str, Any]]] = []
    indexes: dict[str, int] = {}
    for specification in specifications:
        identifier = specification["blockID"]
        if identifier not in indexes:
            indexes[identifier] = len(blocks)
            blocks.append([])
        blocks[indexes[identifier]].append(specification)
    return blocks


def block_is_thermally_valid(paths: list[Path]) -> bool:
    return all(
        json.loads(path.read_text()).get("thermal", {}).get("remainedNominal") is True
        for path in paths
    )


def run_formal_blocks(
    env: dict[str, str], device_id: str, private_values: list[str],
    identity: dict[str, Any], plan_digest: str, claim_family_digest: str,
    specifications: list[dict[str, Any]], cooldown_seconds: int,
) -> tuple[list[Path], list[dict[str, Any]]]:
    accepted: list[Path] = []
    attempts: list[dict[str, Any]] = []
    blocks = grouped_blocks(specifications)
    for block_index, block in enumerate(blocks, start=1):
        identifier = block[0]["blockID"]
        if len(block) != len(A_TIER_HEADLESS):
            raise RuntimeError(f"formal block {identifier} does not contain all A-tier headless comparators")
        accepted_block: list[Path] | None = None
        for attempt in range(1, 4):
            print(
                f"Formal block {block_index}/{len(blocks)} attempt {attempt}/3: {identifier}",
                flush=True,
            )
            current = [
                run_one(
                    env, device_id, private_values, identity,
                    plan_digest, claim_family_digest, specification,
                )
                for specification in block
            ]
            valid = block_is_thermally_valid(current)
            attempts.append({"blockID": identifier, "attempt": attempt, "thermalValid": valid})
            if valid:
                accepted_block = current
                break
            for path in current:
                path.unlink(missing_ok=True)
            if attempt < 3:
                print(
                    f"Thermal drift invalidated {identifier}; cooling for {cooldown_seconds}s",
                    flush=True,
                )
                time.sleep(cooldown_seconds)
        if accepted_block is None:
            raise RuntimeError(f"formal block {identifier} remained thermally invalid after three attempts")
        accepted.extend(accepted_block)
        if block_index < len(blocks):
            time.sleep(cooldown_seconds)
    return accepted, attempts


def aggregate(
    identity: dict[str, Any], plan_digest: str, claim_family_digest: str,
    paths: list[Path], mode: str, blockAttempts: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    records = [json.loads(path.read_text()) for path in paths]
    checks_failed = [
        {
            "comparator": item["comparator"]["name"],
            "workload": item["workloadID"],
            "check": check["identifier"],
            "value": check["value"],
        }
        for item in records
        for check in item["checks"]
        if not check["passed"]
    ]
    report = {
        "schemaVersion": 3,
        "mode": mode,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "planID": "FOVEA-P0B-COMP-V1",
        "sourceIdentity": identity,
        "experimentPlanDigest": plan_digest,
        "claimFamilyDigest": claim_family_digest,
        "deviceProfileID": "iphone-16e-ios27-beta-primary-v1",
        "provisional": True,
        "releaseClaimPermitted": False,
        "runCount": len(records),
        "aTierHeadlessMatrix": A_TIER_HEADLESS,
        "bTierRetained": B_TIER_RETAINED,
        "comparators": sorted({item["comparator"]["name"] for item in records}),
        "workloads": sorted({item["workloadID"] for item in records}),
        "failedChecks": checks_failed,
        "status": "passed" if not checks_failed else "failed",
        "remainingExternalBlockers": [
            "same-device-stable-ios-replication",
            "secondary-lower-performance-physical-device",
        ],
        "runArtifacts": [str(path.relative_to(ROOT)) for path in paths],
        "blockAttempts": blockAttempts or [],
    }
    ARTIFACT_ROOT.mkdir(parents=True, exist_ok=True)
    destination = ARTIFACT_ROOT / f"{mode}-report.json"
    destination.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="Build and run the Fovea Comparative Lab on a physical iPhone.")
    parser.add_argument("--mode", choices=["calibration", "formal"], default="calibration")
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Release")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument(
        "--include-b-tier",
        action="store_true",
        help="Append AlamofireImage only to calibration; formal A-tier blocks remain unchanged.",
    )
    args = parser.parse_args()
    if args.mode == "formal" and args.include_b_tier:
        parser.error("--include-b-tier is calibration-only")
    selected = A_TIER_HEADLESS + (B_TIER_RETAINED if args.include_b_tier else [])
    try:
        env = xcode_environment()
        identity = git_identity()
        plan_digest = canonical_digest(ROOT / "Benchmarks/ComparativeLab/experiment-plan.json")
        claim_family_digest = canonical_digest(ROOT / "Benchmarks/statistical-claim-families.json")
        if SHA64.fullmatch(identity["sourceTreeDigest"]) is None:
            raise RuntimeError("invalid source tree digest")
        profile = json.loads(DEVICE_PROFILE.read_text())
        if profile.get("captureStatus") != "captured" or profile.get("profileID") != "iphone-16e-ios27-beta-primary-v1":
            raise RuntimeError("sanitized physical device profile is missing")
        device_id, private_values = connected_device(env)
        prepare_project(env)
        if not args.skip_build:
            products = build_apps(env, device_id, args.configuration, selected)
            install_apps(env, device_id, products)
        specifications = (
            calibration_runs(selected) if args.mode == "calibration" else formal_runs()
        )
        block_attempts: list[dict[str, Any]] = []
        if args.mode == "formal":
            plan = json.loads((ROOT / "Benchmarks/ComparativeLab/experiment-plan.json").read_text())
            cooldown = int(plan["execution"]["minimumCooldownSecondsBetweenBlocks"])
            paths, block_attempts = run_formal_blocks(
                env, device_id, private_values, identity,
                plan_digest, claim_family_digest, specifications, cooldown,
            )
        else:
            paths = []
            for index, specification in enumerate(specifications, start=1):
                print(f"Run {index}/{len(specifications)}", flush=True)
                paths.append(
                    run_one(
                        env, device_id, private_values, identity,
                        plan_digest, claim_family_digest, specification,
                    )
                )
        report = aggregate(
            identity, plan_digest, claim_family_digest, paths, args.mode, block_attempts
        )
        print(
            f"Comparative device lab {report['status']}: runs={report['runCount']} "
            f"failedChecks={len(report['failedChecks'])} provisional=true"
        )
        print(f"Artifact: .artifacts/comparative-device-lab/{args.mode}-report.json")
        return 0 if report["status"] == "passed" else 1
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
        print(f"Comparative device lab failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
