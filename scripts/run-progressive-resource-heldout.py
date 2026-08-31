#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
import random
import statistics
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parent
RESEARCH = WORKSPACE / "FoveaImageLifecycleResearch"
CONTRACT = RESEARCH / "data" / "progressive-resource-envelope-contract.json"
SOURCE_AUDIT = RESEARCH / "data" / "progressive-resource-envelope-source-audit.json"
MANIFEST = RESEARCH / "data" / "h013-heldout-progressive-fixture.json"
COMMON_PATH = ROOT / "scripts" / "run-progressive-resource-envelope.py"
ARTIFACT_ROOT = ROOT / ".artifacts" / "performance" / "h013-progressive-resource-heldout"

spec = importlib.util.spec_from_file_location("h013_common", COMMON_PATH)
if spec is None or spec.loader is None:
    raise RuntimeError("unable to load H013 common runner")
common = importlib.util.module_from_spec(spec)
spec.loader.exec_module(common)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def config_id(concurrency: int, threshold: int) -> str:
    staging = "spill-64k" if threshold == 65_536 else "memory-1m"
    return f"T1024-C{concurrency}-{staging}"


def configurations(plan: dict[str, Any]) -> list[dict[str, int | str]]:
    matrix = plan["validationMatrix"]
    targets = matrix["targetPixels"]
    require(targets == [1024], "H013 held-out target matrix drifted")
    concurrencies = matrix["progressiveConcurrency"]
    thresholds = matrix["transportMemoryThresholds"]
    require(concurrencies == [1, 4], "H013 held-out concurrency matrix drifted")
    require(thresholds == [65_536, 1_048_576], "H013 held-out staging matrix drifted")
    return [
        {
            "id": config_id(concurrency, threshold),
            "target": 1024,
            "concurrency": concurrency,
            "threshold": threshold,
        }
        for concurrency in concurrencies
        for threshold in thresholds
    ]


def orders(ids: list[str], count: int, seed: int) -> list[list[str]]:
    rng = random.Random(seed)
    result: list[list[str]] = []
    for _ in range(count):
        row = ids.copy()
        rng.shuffle(row)
        result.append(row)
    return result


def validate_report(
    report: dict[str, Any],
    config: dict[str, int | str],
    plan: dict[str, Any],
) -> None:
    require(report.get("schemaVersion") == 1, "H013 held-out mechanism schema mismatch")
    require(report.get("contract") == "progressive-resource-envelope-v1", "H013 held-out contract mismatch")
    require(report.get("fixtureSHA256") == plan["outputSHA256"], "H013 held-out fixture digest mismatch")
    require(report.get("fixtureByteCount") == plan["outputEncodedBytes"], "H013 held-out fixture byte count mismatch")
    require(report.get("targetPixels") == config["target"], "H013 held-out target mismatch")
    require(report.get("progressiveConcurrency") == config["concurrency"], "H013 held-out concurrency mismatch")
    require(report.get("transportMemoryThreshold") == config["threshold"], "H013 held-out threshold mismatch")
    require(report.get("periodicFootprintSampleMilliseconds") == 1, "H013 held-out periodic sampler drifted")
    require(report.get("allCorrect") is True, f"H013 held-out correctness failed: {config['id']}")
    summary = report.get("summary")
    require(isinstance(summary, dict), "H013 held-out summary missing")
    require(summary.get("finalOwnerBytesAllZero") is True, "H013 held-out owner leak")
    require(summary.get("targetPixelInvariantSatisfied") is True, "H013 held-out target invariant failed")
    require(summary.get("recorderDroppedSampleCount") == 0, "H013 held-out recorder dropped samples")
    require(summary.get("periodicSampleCount", 0) > 0, "H013 held-out periodic sample missing")
    require(summary.get("allFootprintSamplesAvailable") is True, "H013 held-out footprint sample missing")
    require(
        isinstance(summary.get("allLifetimePeakSamplesAvailable"), bool),
        "H013 held-out lifetime peak availability diagnostic missing",
    )
    baseline_lifetime = summary.get("baselinePhysicalFootprintLifetimePeakBytes")
    first_preparation_lifetime = summary.get("firstPreparationPhysicalFootprintLifetimePeakBytes")
    barrier_lifetime = summary.get("progressivePhaseBarrierPhysicalFootprintLifetimePeakBytes")
    full_run_lifetime = summary.get("fullRunPhysicalFootprintLifetimePeakBytes")
    require(
        all(isinstance(value, int) and value >= 0 for value in (
            baseline_lifetime, first_preparation_lifetime, barrier_lifetime, full_run_lifetime
        )),
        "H013 held-out lifetime peak summary invalid",
    )
    require(
        baseline_lifetime
        <= first_preparation_lifetime
        <= barrier_lifetime
        <= full_run_lifetime,
        "H013 held-out lifetime peak phase ordering invalid",
    )
    require(
        summary.get("progressivePhaseBarrierReadyCount") == 1,
        "H013 held-out progressive-phase barrier ready count mismatch",
    )
    require(
        summary.get("progressivePhaseBarrierPreparationOwnerCount") == config["concurrency"],
        "H013 held-out progressive-phase barrier preparation-owner count mismatch",
    )
    require(
        summary.get("firstPreparationLifetimePeakCoversCompleteProgressivePhase")
        is (config["concurrency"] == 1),
        "H013 held-out first-preparation lifetime phase coverage mismatch",
    )
    require(
        summary.get("peakActiveSessionCount") == config["concurrency"],
        "H013 held-out requested concurrency was not simultaneously observed",
    )
    require(
        summary.get("peakActivePreparationCount") == config["concurrency"],
        "H013 held-out preparation owners never reached requested concurrency",
    )
    require(
        summary.get("peakPreparationEncodedBytes", 0) >= plan["outputEncodedBytes"],
        "H013 held-out preparation byte charge missing",
    )


def run_configuration(
    binary: Path,
    config: dict[str, int | str],
    plan: dict[str, Any],
    *,
    env: dict[str, str],
    raw_path: Path,
) -> dict[str, Any]:
    result = common.run(
        [
            str(binary),
            "--progressive-resource-mechanism",
            "--progressive-heldout-12mp",
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
    validate_report(report, config, plan)
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    raw_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return report


def summarize(blocks: list[dict[str, Any]], ids: list[str]) -> dict[str, Any]:
    fields = (
        "peakPhysicalFootprintDeltaBytes",
        "baselinePhysicalFootprintLifetimePeakBytes",
        "firstPreparationPhysicalFootprintLifetimePeakBytes",
        "firstPreparationPhysicalFootprintLifetimePeakIncreaseBytes",
        "progressivePhaseBarrierPhysicalFootprintBytes",
        "progressivePhaseBarrierPhysicalFootprintLifetimePeakBytes",
        "progressivePhaseBarrierPhysicalFootprintLifetimePeakIncreaseBytes",
        "progressivePhaseBarrierPreparationOwnerCount",
        "progressivePhaseBarrierReadyCount",
        "fullRunPhysicalFootprintLifetimePeakBytes",
        "fullRunPhysicalFootprintLifetimePeakIncreaseBytes",
        "peakHostVisibleLogicalBytes",
        "peakTransportLogicalBytes",
        "peakRelayPendingBytes",
        "peakProgressHandoffBytes",
        "peakSessionEncodedBytes",
        "peakPreparationEncodedBytes",
        "peakPreviewLogicalBytes",
        "peakActivePreparationCount",
        "periodicSampleCount",
    )
    result: dict[str, Any] = {}
    for key in ids:
        metrics: dict[str, Any] = {}
        for field in fields:
            values = [int(block["configurations"][key]["summary"][field]) for block in blocks]
            metrics[field] = {
                "byBlock": values,
                "minimum": min(values),
                "median": int(statistics.median(values)),
                "maximum": max(values),
            }
        result[key] = {"metrics": metrics}
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--output-name", default="h013-heldout-12mp-directional-v1")
    args = parser.parse_args()

    contract = json.loads(CONTRACT.read_text(encoding="utf-8"))
    require(contract.get("contract") == "progressive-resource-envelope-v1", "H013 contract drifted")
    plan = contract.get("heldOutFixturePlan")
    require(isinstance(plan, dict) and plan.get("id") == "H013-heldout-12mp-v1", "H013 held-out plan missing")
    runner_sha = common.sha256_file(Path(__file__).resolve())
    common_runner_sha = common.sha256_file(COMMON_PATH)
    source_audit_sha = common.sha256_file(SOURCE_AUDIT)
    require(plan.get("runnerSHA256") == runner_sha, "H013 held-out runner binding mismatch")
    require(plan.get("commonRunnerSHA256") == common_runner_sha, "H013 held-out common runner binding mismatch")
    source_audit_binding = contract.get("sourceAudit")
    require(
        isinstance(source_audit_binding, dict)
        and source_audit_binding.get("sha256") == source_audit_sha,
        "H013 held-out source-audit binding mismatch",
    )
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    require(manifest.get("fixtureID") == plan["id"], "H013 held-out manifest identity mismatch")
    require(manifest.get("output", {}).get("sha256") == plan["outputSHA256"], "H013 held-out manifest digest mismatch")
    require(manifest.get("output", {}).get("encodedBytes") == plan["outputEncodedBytes"], "H013 held-out manifest size mismatch")
    require(manifest.get("generator", {}).get("sha256") == plan["generatorSHA256"], "H013 held-out generator binding mismatch")

    matrix = plan["validationMatrix"]
    require(matrix.get("freshProcessPerConfiguration") is True, "H013 held-out fresh-process rule drifted")
    warmup_count = int(matrix["warmupBlocks"])
    measured_count = int(matrix["directionalMeasuredBlocks"])
    seed = int(matrix["randomSeed"])
    require(warmup_count == 1 and measured_count == 3, "H013 held-out block design drifted")

    env = common.environment()
    binary = common.existing_binary(env) if args.skip_build else common.build_binary(env)
    dependency = common.dependency_binding(env)
    require(
        dependency["imageCraftDependencyMode"] == "resolved",
        "H013 held-out baseline requires resolved ImageCraft",
    )
    source_identity = common.runtime_source_identity(env, dependency)
    require(
        source_identity["ImageCraft"]["includesWorkingTreeChanges"] is False,
        "H013 held-out resolved ImageCraft checkout must be clean",
    )

    configs_list = configurations(plan)
    configs = {str(row["id"]): row for row in configs_list}
    ids = [str(row["id"]) for row in configs_list]
    all_orders = orders(ids, warmup_count + measured_count, seed)
    output_dir = ARTIFACT_ROOT / args.output_name
    require(not output_dir.exists(), f"H013 held-out output already exists: {output_dir}")
    output_dir.mkdir(parents=True)

    for block_index, order in enumerate(all_orders[:warmup_count]):
        print(f"H013 held-out warmup {block_index + 1}/{warmup_count}", flush=True)
        for key in order:
            run_configuration(
                binary,
                configs[key],
                plan,
                env=env,
                raw_path=output_dir / "raw" / f"warmup-{block_index:02d}" / f"{key}.json",
            )

    blocks: list[dict[str, Any]] = []
    for block_index, order in enumerate(all_orders[warmup_count:]):
        print(f"H013 held-out measured block {block_index + 1}/{measured_count}", flush=True)
        reports: dict[str, Any] = {}
        for key in order:
            reports[key] = run_configuration(
                binary,
                configs[key],
                plan,
                env=env,
                raw_path=output_dir / "raw" / f"block-{block_index:02d}" / f"{key}.json",
            )
        current_dependency = common.dependency_binding(env)
        require(current_dependency == dependency, "H013 held-out dependency resolution changed")
        require(
            common.runtime_source_identity(env, current_dependency) == source_identity,
            "H013 held-out source changed during measured block",
        )
        blocks.append({"blockIndex": block_index, "order": order, "configurations": reports})

    summary = summarize(blocks, ids)
    report = {
        "schema": 1,
        "contract": "progressive-resource-envelope-v1",
        "evidenceClass": "directional-heldout-host",
        "fixtureID": plan["id"],
        "fixtureSHA256": plan["outputSHA256"],
        "fixtureByteCount": plan["outputEncodedBytes"],
        "manifestSHA256": common.sha256_file(MANIFEST),
        "generatorSHA256": plan["generatorSHA256"],
        "runnerSHA256": runner_sha,
        "commonRunnerSHA256": common_runner_sha,
        "sourceAuditSHA256": source_audit_sha,
        "contractSHA256": common.sha256_file(CONTRACT),
        "sourceIdentities": source_identity,
        "dependencyBinding": dependency,
        "randomSeed": seed,
        "warmupBlockCount": warmup_count,
        "measuredBlockCount": measured_count,
        "configurationCount": len(ids),
        "status": "completed-directional-heldout-capture-candidate-envelope-validation-not-eligible",
        "allConfigurationsCorrect": True,
        "zeroOwnerLeaks": True,
        "heldOutValidationPassed": True,
        "heldOutMechanismCapturePassed": True,
        "candidateEnvelopeHeldOutValidationEligible": False,
        "candidateEnvelopeHeldOutValidationCompleted": False,
        "candidateEnvelopeHeldOutValidationBlocker": (
            "no candidate progressive reservation formula was preregistered before this 12MP capture; "
            "the observed 12MP metrics must not be used to fit or retune that future formula, and formal "
            "post-fit validation requires a new sealed fixture that has not been inspected before formula freeze"
        ),
        "candidateEnvelopeEligible": False,
        "candidateEnvelopeBlocker": (
            "held-out validates the larger-source progressive-phase process high-water under the lab-only all-preparations barrier, "
            "but a source-derived private-transient reservation function and production shared-entry/session-lifetime reservation "
            "remain unestablished; quiet-host replication and physical-device production-URLSession validation remain pending"
        ),
        "configurations": summary,
        "blocks": blocks,
    }
    report_path = output_dir / "report.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"H013 held-out report: {report_path.relative_to(ROOT)}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"H013 held-out runner failed: {error}", file=sys.stderr)
        raise SystemExit(1)
