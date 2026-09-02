#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import random
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parent
IMAGECRAFT_ROOT = WORKSPACE / "ImageCraft"
AKASHIC_ROOT = WORKSPACE / "Akashic"
RESEARCH_ROOT = WORKSPACE / "FoveaImageLifecycleResearch"
CONTRACT_PATH = RESEARCH_ROOT / "data" / "progressive-resource-envelope-contract.json"
ANALYZER_PATH = RESEARCH_ROOT / "scripts" / "analyze_progressive_resource_envelope.py"
ARTIFACT_ROOT = ROOT / ".artifacts" / "performance" / "h013-progressive-resource"
TARGETS = (128, 512, 1024)
CONCURRENCIES = (1, 2, 4)
THRESHOLDS = (65536, 1048576)
SEED = 20260811

sys.path.insert(0, str(ROOT / "scripts"))
from comparative_simulator_support import assert_measurement_host_quiet  # noqa: E402


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def run(
    argv: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    timeout: int = 600,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        argv,
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    if check and result.returncode != 0:
        print(result.stdout[-12_000:], file=sys.stderr)
        print(result.stderr[-12_000:], file=sys.stderr)
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(argv[:8])}")
    return result


def environment() -> dict[str, str]:
    env = os.environ.copy()
    if not env.get("DEVELOPER_DIR"):
        env["DEVELOPER_DIR"] = run(
            [str(ROOT / "scripts" / "select-xcode.sh")],
            cwd=ROOT,
            env=env,
            timeout=60,
        ).stdout.strip()
    return env


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_identity(root: Path, env: dict[str, str]) -> dict[str, Any]:
    head = run(["git", "rev-parse", "HEAD"], cwd=root, env=env, timeout=30).stdout.strip()
    dirty = bool(run(["git", "status", "--porcelain=v1"], cwd=root, env=env, timeout=30).stdout.strip())
    digest = hashlib.sha256()
    digest.update(b"h013-working-tree-v1\0" + head.encode() + b"\0")
    diff = subprocess.run(
        ["git", "diff", "--binary", "HEAD"],
        cwd=root,
        env=env,
        stdout=subprocess.PIPE,
        check=True,
        timeout=60,
    ).stdout
    digest.update(diff)
    untracked = run(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"],
        cwd=root,
        env=env,
        timeout=30,
    ).stdout.split("\0")
    for relative in sorted(item for item in untracked if item):
        path = root / relative
        if path.is_file() and not path.is_symlink():
            digest.update(relative.encode() + b"\0" + path.read_bytes() + b"\0")
    return {
        "commit": head,
        "workingTreeDigest": digest.hexdigest(),
        "includesWorkingTreeChanges": dirty,
    }


def runtime_dependency_root(name: str, mode: str) -> Path:
    if name == "ImageCraft":
        sibling = IMAGECRAFT_ROOT
    elif name == "Akashic":
        sibling = AKASHIC_ROOT
    else:
        raise RuntimeError(f"unsupported H013 runtime dependency: {name}")
    if mode == "local-edited":
        require(sibling.is_dir(), f"missing local-edited {name} dependency: {sibling}")
        return sibling
    require(mode == "resolved", f"invalid {name} dependency mode: {mode}")
    checkout = ROOT / ".build" / "checkouts" / name
    require(checkout.is_dir(), f"missing resolved {name} checkout: {checkout}")
    return checkout


def runtime_source_identity(
    env: dict[str, str],
    dependency: dict[str, Any],
) -> dict[str, Any]:
    imagecraft_root = runtime_dependency_root(
        "ImageCraft", str(dependency["imageCraftDependencyMode"])
    )
    akashic_root = runtime_dependency_root(
        "Akashic", str(dependency["akashicDependencyMode"])
    )
    return {
        "Fovea": git_identity(ROOT, env),
        "ImageCraft": git_identity(imagecraft_root, env),
        "Akashic": git_identity(akashic_root, env),
    }


def dependency_binding(env: dict[str, str]) -> dict[str, Any]:
    graph = run(
        ["xcrun", "swift", "package", "show-dependencies", "--format", "json"],
        cwd=ROOT,
        env=env,
        timeout=180,
    ).stdout
    encoded = graph.encode()
    imagecraft_local = str(IMAGECRAFT_ROOT) in graph
    akashic_local = str(AKASHIC_ROOT) in graph
    package_resolved = ROOT / "Package.resolved"
    return {
        "dependencyGraphSHA256": hashlib.sha256(encoded).hexdigest(),
        "packageResolvedSHA256": sha256_file(package_resolved) if package_resolved.is_file() else None,
        "imageCraftDependencyMode": "local-edited" if imagecraft_local else "resolved",
        "akashicDependencyMode": "local-edited" if akashic_local else "resolved",
    }


def config_id(target: int, concurrency: int, threshold: int) -> str:
    threshold_id = "spill-64k" if threshold == 65536 else "memory-1m"
    return f"T{target}-C{concurrency}-{threshold_id}"


def configurations() -> list[dict[str, int | str]]:
    return [
        {
            "id": config_id(target, concurrency, threshold),
            "target": target,
            "concurrency": concurrency,
            "threshold": threshold,
        }
        for target in TARGETS
        for concurrency in CONCURRENCIES
        for threshold in THRESHOLDS
    ]


def randomized_orders(total_blocks: int) -> list[list[str]]:
    ids = [str(item["id"]) for item in configurations()]
    rng = random.Random(SEED)
    orders: list[list[str]] = []
    for _ in range(total_blocks):
        order = ids.copy()
        rng.shuffle(order)
        orders.append(order)
    return orders


def build_binary(env: dict[str, str]) -> Path:
    run(
        [
            "xcrun",
            "swift",
            "build",
            "-c",
            "release",
            "--product",
            "FoveaNetworkLab",
            "-Xswiftc",
            "-warnings-as-errors",
        ],
        cwd=ROOT,
        env=env,
        timeout=1_800,
    )
    bin_path = Path(
        run(
            ["xcrun", "swift", "build", "-c", "release", "--show-bin-path"],
            cwd=ROOT,
            env=env,
            timeout=180,
        ).stdout.strip()
    )
    binary = bin_path / "FoveaNetworkLab"
    require(binary.is_file(), f"missing FoveaNetworkLab binary: {binary}")
    return binary


def existing_binary(env: dict[str, str]) -> Path:
    bin_path = Path(
        run(
            ["xcrun", "swift", "build", "-c", "release", "--show-bin-path"],
            cwd=ROOT,
            env=env,
            timeout=180,
        ).stdout.strip()
    )
    binary = bin_path / "FoveaNetworkLab"
    require(binary.is_file(), "--skip-build requires an existing Release FoveaNetworkLab")
    return binary


def validate_report(report: dict[str, Any], config: dict[str, int | str]) -> None:
    require(report.get("schemaVersion") == 1, "unexpected H013 mechanism report schema")
    require(report.get("contract") == "progressive-resource-envelope-v1", "H013 contract mismatch")
    require(report.get("allCorrect") is True, f"H013 correctness failed: {config['id']}")
    require(report.get("targetPixels") == config["target"], "H013 target mismatch")
    require(report.get("progressiveConcurrency") == config["concurrency"], "H013 concurrency mismatch")
    require(report.get("transportMemoryThreshold") == config["threshold"], "H013 threshold mismatch")
    require(
        report.get("periodicFootprintSampleMilliseconds") == 1,
        "H013 periodic footprint interval mismatch",
    )
    require(
        report.get("fixtureSHA256")
        == "494941339b490cededbb482a47ff7e1352761a4dcc93c82527775ae46c573a87",
        "H013 fixture digest mismatch",
    )
    summary = report.get("summary")
    require(isinstance(summary, dict), "H013 summary missing")
    require(summary.get("finalOwnerBytesAllZero") is True, "H013 owner leak")
    require(summary.get("targetPixelInvariantSatisfied") is True, "H013 target invariant failed")
    require(summary.get("recorderDroppedSampleCount") == 0, "H013 recorder dropped samples")
    require(summary.get("periodicSampleCount", 0) > 0, "H013 periodic footprint sample missing")
    require(summary.get("allFootprintSamplesAvailable") is True, "H013 footprint sample missing")
    require(
        isinstance(summary.get("allLifetimePeakSamplesAvailable"), bool),
        "H013 lifetime peak availability diagnostic missing",
    )
    baseline_lifetime = summary.get("baselinePhysicalFootprintLifetimePeakBytes")
    first_preparation_lifetime = summary.get("firstPreparationPhysicalFootprintLifetimePeakBytes")
    barrier_lifetime = summary.get("progressivePhaseBarrierPhysicalFootprintLifetimePeakBytes")
    full_run_lifetime = summary.get("fullRunPhysicalFootprintLifetimePeakBytes")
    require(
        all(isinstance(value, int) and value >= 0 for value in (
            baseline_lifetime, first_preparation_lifetime, barrier_lifetime, full_run_lifetime
        )),
        "H013 lifetime peak summary invalid",
    )
    require(
        baseline_lifetime
        <= first_preparation_lifetime
        <= barrier_lifetime
        <= full_run_lifetime,
        "H013 lifetime peak phase ordering invalid",
    )
    require(
        summary.get("progressivePhaseBarrierReadyCount") == 1,
        "H013 progressive-phase barrier ready count mismatch",
    )
    require(
        summary.get("progressivePhaseBarrierPreparationOwnerCount") == config["concurrency"],
        "H013 progressive-phase barrier preparation-owner count mismatch",
    )
    require(
        summary.get("firstPreparationLifetimePeakCoversCompleteProgressivePhase")
        is (config["concurrency"] == 1),
        "H013 first-preparation lifetime phase coverage mismatch",
    )
    require(
        summary.get("peakActiveSessionCount") == config["concurrency"],
        "H013 requested concurrency was not simultaneously observed",
    )
    require(
        summary.get("peakActivePreparationCount") == config["concurrency"],
        "H013 progressive preparation owners never reached requested concurrency",
    )
    require(
        summary.get("peakPreparationEncodedBytes", 0) >= report.get("fixtureByteCount", 0),
        "H013 progressive preparation bytes were not accounted",
    )


def run_configuration(
    binary: Path,
    config: dict[str, int | str],
    *,
    env: dict[str, str],
    raw_path: Path,
) -> dict[str, Any]:
    result = run(
        [
            str(binary),
            "--progressive-resource-mechanism",
            "--progressive-target-pixels",
            str(config["target"]),
            "--progressive-concurrency",
            str(config["concurrency"]),
            "--progressive-transport-threshold",
            str(config["threshold"]),
        ],
        cwd=ROOT,
        env=env,
        timeout=180,
    )
    report = json.loads(result.stdout)
    validate_report(report, config)
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    raw_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--blocks", type=int, default=3)
    parser.add_argument("--warmup-blocks", type=int, default=1)
    parser.add_argument("--diagnostic", action="store_true")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--output-name")
    args = parser.parse_args()

    contract = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
    require(contract.get("schema") == 1, "unexpected H013 contract schema")
    require(contract.get("contract") == "progressive-resource-envelope-v1", "unexpected H013 contract")
    if args.diagnostic:
        require(args.blocks >= 1, "diagnostic campaign requires at least one block")
    else:
        require(args.blocks >= 5, "quiet-host campaign requires at least five measured blocks")
    require(args.warmup_blocks >= 0, "warmup block count must be non-negative")

    env = environment()
    binary = existing_binary(env) if args.skip_build else build_binary(env)
    dependency = dependency_binding(env)
    source_identity = runtime_source_identity(env, dependency)
    contract_sha = sha256_file(CONTRACT_PATH)
    analyzer_sha = sha256_file(ANALYZER_PATH)

    if not args.diagnostic:
        require(
            dependency["imageCraftDependencyMode"] == "resolved",
            "claim-bearing H013 baseline requires resolved ImageCraft at the audited Package.resolved pin",
        )
        require(
            source_identity["ImageCraft"]["includesWorkingTreeChanges"] is False,
            "resolved H013 ImageCraft runtime checkout must be clean",
        )
        assert_measurement_host_quiet(root=ROOT)

    name = args.output_name or (
        "h013-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    )
    output_dir = ARTIFACT_ROOT / name
    require(not output_dir.exists(), f"output already exists: {output_dir.relative_to(ROOT)}")
    output_dir.mkdir(parents=True)

    configs = {str(item["id"]): item for item in configurations()}
    orders = randomized_orders(args.warmup_blocks + args.blocks)
    warmup_orders = orders[: args.warmup_blocks]
    measured_orders = orders[args.warmup_blocks :]

    for block_index, order in enumerate(warmup_orders):
        print(f"H013 warmup {block_index + 1}/{len(warmup_orders)}", flush=True)
        for key in order:
            run_configuration(
                binary,
                configs[key],
                env=env,
                raw_path=output_dir / "raw" / f"warmup-{block_index:02d}" / f"{key}.json",
            )

    blocks: list[dict[str, Any]] = []
    for block_index, order in enumerate(measured_orders):
        if not args.diagnostic:
            assert_measurement_host_quiet(root=ROOT)
        print(f"H013 measured block {block_index + 1}/{len(measured_orders)}", flush=True)
        reports: dict[str, Any] = {}
        for key in order:
            reports[key] = run_configuration(
                binary,
                configs[key],
                env=env,
                raw_path=output_dir / "raw" / f"block-{block_index:02d}" / f"{key}.json",
            )
        current_dependency = dependency_binding(env)
        require(
            current_dependency == dependency,
            f"dependency resolution changed during H013 block {block_index}",
        )
        current_identity = runtime_source_identity(env, current_dependency)
        require(current_identity == source_identity, f"source changed during H013 block {block_index}")
        blocks.append(
            {
                "blockIndex": block_index,
                "order": order,
                "configurations": reports,
            }
        )

    final_dependency = dependency_binding(env)
    require(final_dependency == dependency, "dependency resolution changed during H013 campaign")
    require(
        runtime_source_identity(env, final_dependency) == source_identity,
        "source changed during H013 campaign",
    )

    input_payload = {
        "schema": 1,
        "contract": "progressive-resource-envelope-v1",
        "evidenceClass": "directional-host" if args.diagnostic else "quiet-host-mechanism",
        "contractSHA256": contract_sha,
        "analyzerSHA256": analyzer_sha,
        "sourceIdentities": source_identity,
        "dependencyBinding": dependency,
        "randomSeed": SEED,
        "warmupBlockCount": args.warmup_blocks,
        "warmupOrders": warmup_orders,
        "hostQuiescenceGateEnforced": not args.diagnostic,
        "formalDeviceClaimEligible": False,
        "blocks": blocks,
    }
    input_path = output_dir / "input.json"
    input_path.write_text(json.dumps(input_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    analysis_path = output_dir / "analysis.json"
    run(
        ["python3", str(ANALYZER_PATH), str(input_path), "--output", str(analysis_path)],
        cwd=RESEARCH_ROOT,
        env=env,
        timeout=120,
    )
    analysis = json.loads(analysis_path.read_text(encoding="utf-8"))
    report = {
        "schema": 1,
        "contract": "progressive-resource-envelope-v1",
        "status": "completed-directional" if args.diagnostic else "completed-quiet-host-mechanism",
        "sourceIdentities": source_identity,
        "dependencyBinding": dependency,
        "contractSHA256": contract_sha,
        "analyzerSHA256": analyzer_sha,
        "inputSHA256": sha256_file(input_path),
        "analysisSHA256": sha256_file(analysis_path),
        "measuredBlockCount": analysis["measuredBlockCount"],
        "configurationCount": analysis["configurationCount"],
        "allConfigurationsCorrect": analysis["allConfigurationsCorrect"],
        "zeroOwnerLeaks": analysis["zeroOwnerLeaks"],
        "candidateEnvelopeEligible": analysis["candidateEnvelopeEligible"],
        "candidateEnvelopeBlocker": analysis["candidateEnvelopeBlocker"],
        "formalDeviceClaimEligible": False,
    }
    report_path = output_dir / "report.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"H013 report: {report_path.relative_to(ROOT)}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"H013 progressive resource runner failed: {error}", file=sys.stderr)
        raise SystemExit(1)
